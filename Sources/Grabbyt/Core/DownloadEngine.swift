import Foundation

public struct DownloadRequest: Sendable {
    public var url: String
    public var mode: MediaMode
    public var quality: VideoQuality
    public var audioFormat: AudioFormat
    public var destination: URL
    public var preferredBrowser: Browser?
    /// Argumentos extra para yt-dlp (p. ej. --ignore-no-formats-error en carruseles mixtos).
    public var extraYtDlpArgs: [String] = []

    public init(url: String, mode: MediaMode, quality: VideoQuality = .best, audioFormat: AudioFormat = .mp3,
                destination: URL, preferredBrowser: Browser?) {
        self.url = url
        self.mode = mode
        self.quality = quality
        self.audioFormat = audioFormat
        self.destination = destination
        self.preferredBrowser = preferredBrowser
    }
}

public enum DownloadEvent: Sendable {
    case attempt(number: Int, config: AttemptConfig)
    case status(String)
    case title(String)
    case progress(fraction: Double?, speed: String?, eta: String?)
    case log(String)
    case attemptFailed(FailureKind)
    case fallback(String)           // estrategia fuera de yt-dlp (p. ej. API de fxtwitter)
}

public enum DownloadOutcome: Sendable {
    case success(files: [URL])
    case failure(kind: FailureKind, message: String)
    case cancelled
}

/// Orquesta todas las estrategias: yt-dlp (con su propia cadena de reintentos) y, si falla,
/// APIs específicas, gallery-dl, descarga directa, lectura del HTML y WebKit.
public final class DownloadEngine: @unchecked Sendable {
    private let tools: ToolManager
    private let lock = NSLock()
    private var currentRunner: ProcessRunner?
    private var cancelled = false

    public init(tools: ToolManager = .shared) {
        self.tools = tools
    }

    public func cancel() {
        let runner: ProcessRunner? = lock.withLock {
            cancelled = true
            return currentRunner
        }
        runner?.cancel()
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled } || Task.isCancelled
    }

    public enum Stage: String {
        case ytdlp, postImages, twitter, galleryDL, direct, html, webview
    }

    private enum StageResult {
        case success([URL])
        case failed(FailureKind, String?)
        case cancelled
    }

    /// Orden de etapas según el modo y el tipo de link.
    public static func stages(for request: DownloadRequest) -> [Stage] {
        let isTweet = TwitterFallback.tweetID(from: request.url) != nil
        var list: [Stage]
        switch request.mode {
        case .images:
            list = [.twitter, .postImages, .galleryDL, .html, .ytdlp, .webview]
        case .audio:
            list = [.ytdlp, .twitter, .direct, .html, .webview]
        case .video:
            list = DirectDownloader.looksLikeFile(request.url)
                ? [.direct, .ytdlp, .html, .webview]
                : [.ytdlp, .twitter, .postImages, .galleryDL, .direct, .html, .webview]
        }
        if !isTweet { list.removeAll { $0 == .twitter } }
        return list
    }

    public func run(_ request: DownloadRequest, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> DownloadOutcome {
        try? FileManager.default.createDirectory(at: request.destination, withIntermediateDirectories: true)
        var ytFailure: (FailureKind, String?)?
        var lastFailure: (FailureKind, String?) = (.noMedia, nil)

        for stage in Self.stages(for: request) {
            if isCancelled { return .cancelled }
            if stage != .ytdlp { onEvent(.fallback(Self.stageName(stage))) }
            let result: StageResult
            switch stage {
            case .ytdlp: result = await runYtDlpChain(request, onEvent: onEvent)
            case .postImages: result = await runPostImages(request, onEvent: onEvent)
            case .twitter: result = await runTwitter(request, onEvent: onEvent)
            case .galleryDL: result = await runGalleryDL(request, onEvent: onEvent)
            case .direct: result = await runDirect(request, onEvent: onEvent)
            case .html: result = await runHTML(request, onEvent: onEvent)
            case .webview: result = await runWebView(request, onEvent: onEvent)
            }
            switch result {
            case .success(let files): return .success(files: files)
            case .cancelled: return .cancelled
            case .failed(let kind, let message):
                if stage == .ytdlp {
                    ytFailure = (kind, message)
                    // Estos fallos no los arregla ninguna otra estrategia.
                    if kind == .geoBlocked || kind == .network { return .failure(kind: kind, message: message ?? kind.userMessage) }
                } else {
                    onEvent(.attemptFailed(kind))
                }
                lastFailure = (kind, message)
            }
        }
        if isCancelled { return .cancelled }
        let (kind, message) = ytFailure ?? lastFailure
        var text = message ?? kind.userMessage
        if request.mode == .video, kind == .noMedia || kind == .unsupportedURL || kind == .imagesOnly {
            text += "\nSi es un post de fotos, prueba el modo Imágenes."
        }
        return .failure(kind: kind, message: text)
    }

    static func stageName(_ stage: Stage) -> String {
        switch stage {
        case .ytdlp: "yt-dlp"
        case .postImages: "imágenes del post (yt-dlp)"
        case .twitter: "API de fxtwitter/vxtwitter"
        case .galleryDL: "gallery-dl (imágenes y galerías)"
        case .direct: "descarga directa"
        case .html: "leer el HTML de la página"
        case .webview: "navegador invisible (detectar video)"
        }
    }

    // MARK: - Etapa: yt-dlp con su cadena de reintentos

    private func runYtDlpChain(_ request: DownloadRequest, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> StageResult {
        guard await tools.path(for: .ytdlp) != nil else {
            return .failed(.unknown, "yt-dlp no está instalado. Ábrelo en Ajustes → Herramientas.")
        }
        let hasFfmpeg = await tools.path(for: .ffmpeg) != nil
        let host = URL(string: request.url)?.host?.lowercased() ?? ""
        var planner = AttemptPlanner(
            installedBrowsers: Browser.withReadableCookies(),
            preferredBrowser: request.preferredBrowser,
            isYouTube: host.contains("youtube.com") || host.contains("youtu.be")
        )
        var config = planner.first(hasFfmpeg: hasFfmpeg)
        var lastFailure = FailureKind.unknown
        var primaryFailure: FailureKind?   // el último fallo "real" (no de cookies), para el mensaje final
        var lastErrorLine = ""

        while true {
            if isCancelled { return .cancelled }
            onEvent(.attempt(number: planner.attempts, config: config))

            if config.updateFirst {
                onEvent(.status("Actualizando yt-dlp…"))
                let ok = await tools.updateYtDlp(force: false)
                onEvent(.log(ok ? "yt-dlp actualizado" : "No se pudo actualizar yt-dlp"))
            }
            if config.waitSeconds > 0 {
                onEvent(.status("Esperando \(config.waitSeconds)s antes de reintentar…"))
                try? await Task.sleep(for: .seconds(config.waitSeconds))
                if isCancelled { return .cancelled }
            }

            onEvent(.status("Analizando link (\(config.summary))…"))
            let result = await runYtDlp(request, config: config, hasFfmpeg: hasFfmpeg, onEvent: onEvent)
            if result.wasCancelled || isCancelled { return .cancelled }

            // Con varios elementos (p. ej. un tweet con 2 videos) yt-dlp puede salir con error
            // aunque haya bajado algo: si hay archivos, cuenta como éxito.
            if !result.files.isEmpty {
                return .success(result.files)
            }
            if result.exitCode == 0 {
                // yt-dlp dice OK pero no reportó archivo (p. ej. ya existía). Lo tratamos como éxito sin ruta.
                if result.output.contains("has already been downloaded") {
                    return .success([])
                }
                lastFailure = .noMedia
            } else {
                lastFailure = ErrorClassifier.classify(result.output)
            }
            // Si pedimos cookies y el fallo no es de cookies pero menciona leerlas, igual es fallo de cookies.
            if config.cookies != nil, lastFailure == .unknown, result.output.lowercased().contains("cookie") {
                lastFailure = .cookieFailure
            }
            lastErrorLine = result.output
                .split(whereSeparator: \.isNewline)
                .last { $0.contains("ERROR") }
                .map(String.init) ?? ""
            onEvent(.attemptFailed(lastFailure))
            if lastFailure != .cookieFailure { primaryFailure = lastFailure }

            guard let next = planner.next(after: lastFailure, previous: config, canUpdate: true) else {
                let reported = primaryFailure ?? lastFailure
                var message = reported.userMessage
                if reported == .unknown, !lastErrorLine.isEmpty {
                    message += "\n" + lastErrorLine.replacingOccurrences(of: "ERROR: ", with: "")
                }
                if reported == .loginRequired, planner.browsers.isEmpty {
                    message += "\nNo encontré cookies de ningún navegador: inicia sesión en Chrome/Firefox, o da a Grabbyt “Acceso total al disco” para usar Safari."
                }
                return .failed(reported, message)
            }
            config = next
        }
    }

    // MARK: - Etapa: imágenes del post (metadatos de yt-dlp)

    private func runPostImages(_ request: DownloadRequest, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> StageResult {
        guard let ytdlp = await tools.path(for: .ytdlp) else { return .failed(.unsupportedURL, nil) }
        var cookieOptions: [Browser?] = [nil]
        if let browser = request.preferredBrowser ?? Browser.withReadableCookies().first { cookieOptions.append(browser) }

        for cookies in cookieOptions {
            if isCancelled { return .cancelled }
            onEvent(.status(cookies == nil ? "Buscando las imágenes del post…" : "Buscando imágenes con cookies de \(cookies!.displayName)…"))
            var args = ["-J", "--no-warnings", "--ignore-no-formats-error", "--socket-timeout", "20"]
            if let cookies { args += ["--cookies-from-browser", cookies.rawValue] }
            args += ["--", request.url]
            let result = await runProcess(ytdlp, args)
            if result.wasCancelled { return .cancelled }
            guard result.exitCode == 0,
                  let line = result.output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("{") }),
                  let parsed = PostImages.parse(json: Data(line.utf8)) else {
                if ErrorClassifier.classify(result.output) == .loginRequired { continue }
                return .failed(.noMedia, nil)
            }

            var files: [URL] = []
            let many = parsed.images.count > 1
            for (i, item) in parsed.images.enumerated() {
                if isCancelled { return .cancelled }
                onEvent(.status("Descargando imagen \(i + 1)/\(parsed.images.count)…"))
                onEvent(.progress(fraction: Double(i) / Double(max(parsed.images.count, 1)), speed: nil, eta: nil))
                let ext = ["jpg", "jpeg", "png", "webp", "heic"].contains(item.url.pathExtension.lowercased()) ? item.url.pathExtension : "jpg"
                let name = "\(parsed.owner) - \(item.id)\(many ? " \(i + 1)" : "").\(ext)"
                if let file = try? await DirectDownloader.download(item.url, to: request.destination, preferredName: name, onProgress: { _ in }) {
                    files.append(file)
                }
            }

            // Carrusel mixto en modo Imágenes: bajar también los videos.
            if request.mode == .images, parsed.videoCount > 0 {
                onEvent(.status("Descargando \(parsed.videoCount) video(s) del post…"))
                var videoRequest = request
                videoRequest.mode = .video
                videoRequest.extraYtDlpArgs = ["--ignore-no-formats-error"]
                if case .success(let videos) = await runYtDlpChain(videoRequest, onEvent: onEvent) { files += videos }
            }
            if !files.isEmpty { return .success(files) }
            if parsed.images.isEmpty && parsed.videoCount == 0 { return .failed(.noMedia, nil) }
        }
        return .failed(.imagesOnly, nil)
    }

    // MARK: - Etapa: X/Twitter

    private func runTwitter(_ request: DownloadRequest, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> StageResult {
        guard let tweetID = TwitterFallback.tweetID(from: request.url) else { return .failed(.unsupportedURL, nil) }
        do {
            let files = try await TwitterFallback.download(
                tweetID: tweetID, mode: request.mode, destination: request.destination,
                ffmpeg: await tools.path(for: .ffmpeg)
            ) { onEvent(.status($0)) }
            return .success(files)
        } catch {
            onEvent(.log("fxtwitter: \(error.localizedDescription)"))
            return .failed(.noMedia, nil)
        }
    }

    // MARK: - Etapa: gallery-dl

    private func runGalleryDL(_ request: DownloadRequest, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> StageResult {
        guard let gdl = await tools.path(for: .galleryDL) else {
            onEvent(.log("gallery-dl no está instalado"))
            return .failed(.unsupportedURL, nil)
        }
        let browsers = Browser.withReadableCookies()
        var cookieOptions: [Browser?] = [nil]
        if let preferred = request.preferredBrowser, browsers.contains(preferred) { cookieOptions.append(preferred) }
        else if let first = browsers.first { cookieOptions.append(first) }

        var lastKind = FailureKind.noMedia
        for cookies in cookieOptions {
            if isCancelled { return .cancelled }
            onEvent(.status(cookies == nil ? "Buscando imágenes con gallery-dl…" : "gallery-dl con cookies de \(cookies!.displayName)…"))
            let args = GalleryDL.arguments(url: request.url, destination: request.destination, cookies: cookies)
            onEvent(.log("$ gallery-dl " + args.map(YtDlpArguments.shellQuote).joined(separator: " ")))
            let files = FileCollector()
            let result = await runProcess(gdl, args) { line in
                if let file = GalleryDL.parseFile(line: line) {
                    files.add(file)
                    onEvent(.status("gallery-dl: \(files.urls.count) archivo(s)…"))
                } else {
                    onEvent(.log(line))
                }
            }
            if result.wasCancelled { return .cancelled }
            if !files.urls.isEmpty { return .success(files.urls) }
            lastKind = ErrorClassifier.classify(result.output)
            let lower = result.output.lowercased()
            let needsLogin = lastKind == .loginRequired || lower.contains("401") || lower.contains("403") || lower.contains("login")
            if !needsLogin { break }
        }
        return .failed(lastKind == .unknown ? .noMedia : lastKind, nil)
    }

    // MARK: - Etapa: descarga directa

    private func runDirect(_ request: DownloadRequest, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> StageResult {
        guard let url = URL(string: request.url) else { return .failed(.unsupportedURL, nil) }
        if DirectDownloader.isStream(url) {
            return await downloadCandidate(url, request: request, name: url.deletingPathExtension().lastPathComponent, referer: nil, onEvent: onEvent)
        }
        onEvent(.status("Comprobando si el link es un archivo…"))
        guard await DirectDownloader.mediaContentType(of: url) != nil else { return .failed(.noMedia, nil) }
        return await downloadCandidate(url, request: request, name: nil, referer: nil, onEvent: onEvent)
    }

    // MARK: - Etapa: HTML

    private func runHTML(_ request: DownloadRequest, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> StageResult {
        guard let url = URL(string: request.url) else { return .failed(.unsupportedURL, nil) }
        onEvent(.status("Leyendo la página…"))
        guard let found = try? await HTMLScraper.scrape(url) else { return .failed(.network, nil) }
        if let title = found.title { onEvent(.title(title)) }
        let name = found.title ?? url.host ?? "video"

        if request.mode != .images {
            for candidate in found.videos.prefix(5) {
                if isCancelled { return .cancelled }
                onEvent(.log("HTML → \(candidate.absoluteString)"))
                if case .success(let files) = await downloadCandidate(candidate, request: request, name: name, referer: url.absoluteString, onEvent: onEvent) {
                    return .success(files)
                }
            }
            return .failed(.noMedia, nil)
        }

        var files: [URL] = []
        for (i, image) in found.images.prefix(20).enumerated() {
            if isCancelled { return .cancelled }
            let ext = image.pathExtension.isEmpty ? "jpg" : image.pathExtension
            if let file = try? await DirectDownloader.download(image, to: request.destination, preferredName: "\(name) \(i + 1).\(ext)", referer: url.absoluteString, onProgress: { _ in }) {
                files.append(file)
            }
        }
        return files.isEmpty ? .failed(.noMedia, nil) : .success(files)
    }

    // MARK: - Etapa: WebKit invisible

    private func runWebView(_ request: DownloadRequest, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> StageResult {
        guard let url = URL(string: request.url) else { return .failed(.unsupportedURL, nil) }
        onEvent(.status("Abriendo la página en un navegador invisible…"))
        let found = await WebSniffer.sniff(url)
        if isCancelled { return .cancelled }
        if let title = found.title, !title.isEmpty { onEvent(.title(title)) }
        let name = (found.title?.isEmpty == false ? found.title : nil) ?? url.host ?? "video"
        for candidate in found.media.prefix(4) {
            onEvent(.log("WebKit → \(candidate.absoluteString)"))
            if case .success(let files) = await downloadCandidate(candidate, request: request, name: name, referer: url.absoluteString, onEvent: onEvent) {
                return .success(files)
            }
            if isCancelled { return .cancelled }
        }
        return .failed(.noMedia, nil)
    }

    // MARK: - Ayudantes de fallbacks

    /// Baja una URL de medios (stream con ffmpeg o archivo directo) y la convierte a audio si hace falta.
    private func downloadCandidate(_ url: URL, request: DownloadRequest, name: String?, referer: String?, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> StageResult {
        let ffmpeg = await tools.path(for: .ffmpeg)
        do {
            if DirectDownloader.isStream(url) {
                guard let ffmpeg else { return .failed(.ffmpegMissing, nil) }
                onEvent(.status("Descargando stream con ffmpeg…"))
                onEvent(.progress(fraction: nil, speed: nil, eta: nil))
                let runner = ProcessRunner()
                lock.withLock { currentRunner = runner }
                defer { lock.withLock { currentRunner = nil } }
                let file = try await StreamDownloader.download(
                    url, to: request.destination, name: name ?? "video", mode: request.mode,
                    audioFormat: request.audioFormat, referer: referer, ffmpeg: ffmpeg, runner: runner)
                return .success([file])
            }
            onEvent(.status("Descargando archivo…"))
            let preferred = name.map { n in
                let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
                return "\(n).\(ext)"
            }
            var file = try await DirectDownloader.download(url, to: request.destination, preferredName: preferred, referer: referer) { fraction in
                onEvent(.progress(fraction: fraction, speed: nil, eta: nil))
            }
            if request.mode == .audio, let ffmpeg, !["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"].contains(file.pathExtension.lowercased()) {
                file = await extractAudio(file, format: request.audioFormat, ffmpeg: ffmpeg, onEvent: onEvent)
            }
            return .success([file])
        } catch {
            if isCancelled { return .cancelled }
            onEvent(.log("\(url.lastPathComponent): \(error.localizedDescription)"))
            return .failed(.noMedia, nil)
        }
    }

    private func extractAudio(_ file: URL, format: AudioFormat, ffmpeg: URL, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> URL {
        onEvent(.status("Extrayendo audio…"))
        let out = DirectDownloader.uniqueURL(in: file.deletingLastPathComponent(), name: file.deletingPathExtension().lastPathComponent + "." + format.rawValue)
        let codec = format == .mp3 ? ["-q:a", "0"] : ["-c:a", "aac", "-b:a", "192k"]
        let result = await runProcess(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", file.path, "-vn"] + codec + [out.path])
        guard result.exitCode == 0 else { return file }
        try? FileManager.default.removeItem(at: file)
        return out
    }

    private func runProcess(_ exe: URL, _ args: [String], onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> ProcessRunner.Result {
        let runner = ProcessRunner()
        lock.withLock { currentRunner = runner }
        defer { lock.withLock { currentRunner = nil } }
        if isCancelled { return ProcessRunner.Result(exitCode: -1, output: "", wasCancelled: true) }
        return await runner.run(executable: exe, arguments: args, onLine: onLine)
    }

    // MARK: - yt-dlp

    private struct RunResult {
        var exitCode: Int32
        var output: String
        var wasCancelled: Bool
        var files: [URL]
    }

    private func runYtDlp(_ request: DownloadRequest, config: AttemptConfig, hasFfmpeg: Bool, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> RunResult {
        guard let ytdlp = await tools.path(for: .ytdlp) else {
            return RunResult(exitCode: -1, output: "ERROR: yt-dlp not found", wasCancelled: false, files: [])
        }
        let ffmpegDir = await tools.ffmpegLocation()
        let args = YtDlpArguments.build(request: request, config: config, ffmpegDir: ffmpegDir)
        onEvent(.log("$ yt-dlp " + args.map(YtDlpArguments.shellQuote).joined(separator: " ")))

        let runner = ProcessRunner()
        lock.withLock { currentRunner = runner }
        defer { lock.withLock { currentRunner = nil } }

        let files = FileCollector()
        var env = ["PYTHONUNBUFFERED": "1", "NO_COLOR": "1"]
        if let ffmpegDir {
            env["PATH"] = ffmpegDir.path + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        }

        let result = await runner.run(executable: ytdlp, arguments: args, environment: env) { line in
            if let event = YtDlpArguments.parse(line: line) {
                switch event {
                case .file(let path): files.add(URL(fileURLWithPath: path))
                case .progress(let f, let s, let e): onEvent(.progress(fraction: f, speed: s, eta: e))
                case .title(let t): onEvent(.title(t))
                }
            } else {
                onEvent(.log(line))
            }
        }
        return RunResult(exitCode: result.exitCode, output: result.output, wasCancelled: result.wasCancelled, files: files.urls)
    }
}

private final class FileCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    func add(_ url: URL) { lock.lock(); if !items.contains(url) { items.append(url) }; lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return items }
}
