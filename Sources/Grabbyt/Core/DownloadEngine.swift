import Foundation

public struct DownloadRequest: Sendable {
    public var url: String
    public var mode: MediaMode
    public var destination: URL
    public var preferredBrowser: Browser?

    public init(url: String, mode: MediaMode, destination: URL, preferredBrowser: Browser?) {
        self.url = url
        self.mode = mode
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

/// Corre yt-dlp con la cadena de fallbacks hasta que un intento funcione.
public final class DownloadEngine: @unchecked Sendable {
    private let tools: ToolManager
    private let lock = NSLock()
    private var currentRunner: ProcessRunner?
    private var cancelled = false

    public init(tools: ToolManager = .shared) {
        self.tools = tools
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let runner = currentRunner
        lock.unlock()
        runner?.cancel()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled || Task.isCancelled
    }

    public func run(_ request: DownloadRequest, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> DownloadOutcome {
        guard await tools.path(for: .ytdlp) != nil else {
            return .failure(kind: .unknown, message: "yt-dlp no está instalado. Ábrelo en Ajustes → Herramientas.")
        }
        try? FileManager.default.createDirectory(at: request.destination, withIntermediateDirectories: true)

        let hasFfmpeg = await tools.path(for: .ffmpeg) != nil
        var planner = AttemptPlanner(installedBrowsers: Browser.withReadableCookies(), preferredBrowser: request.preferredBrowser)
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
                return .success(files: result.files)
            }
            if result.exitCode == 0 {
                // yt-dlp dice OK pero no reportó archivo (p. ej. ya existía). Lo tratamos como éxito sin ruta.
                if result.output.contains("has already been downloaded") {
                    return .success(files: [])
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
                if lastFailure != .network, let files = await platformFallback(request, onEvent: onEvent) {
                    return .success(files: files)
                }
                if isCancelled { return .cancelled }
                let reported = primaryFailure ?? lastFailure
                var message = reported.userMessage
                if reported == .unknown, !lastErrorLine.isEmpty {
                    message += "\n" + lastErrorLine.replacingOccurrences(of: "ERROR: ", with: "")
                }
                if reported == .loginRequired, planner.browsers.isEmpty {
                    message += "\nNo encontré cookies de ningún navegador: inicia sesión en Chrome/Firefox, o da a Grabbyt “Acceso total al disco” para usar Safari."
                }
                return .failure(kind: reported, message: message)
            }
            config = next
        }
    }

    // MARK: - Fallbacks por plataforma

    /// Se prueba cuando yt-dlp ya agotó sus estrategias.
    private func platformFallback(_ request: DownloadRequest, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> [URL]? {
        guard let tweetID = TwitterFallback.tweetID(from: request.url) else { return nil }
        onEvent(.fallback("API de fxtwitter/vxtwitter"))
        do {
            let files = try await TwitterFallback.download(
                tweetID: tweetID, mode: request.mode, destination: request.destination,
                ffmpeg: await tools.path(for: .ffmpeg)
            ) { onEvent(.status($0)) }
            return files
        } catch {
            onEvent(.log("fxtwitter: \(error.localizedDescription)"))
            onEvent(.attemptFailed(.noMedia))
            return nil
        }
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
