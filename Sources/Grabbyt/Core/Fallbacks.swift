import Foundation

let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

// MARK: - Descarga directa

/// Descarga archivos sueltos (mp4, jpg, pdf…) con progreso.
public enum DirectDownloader {
    static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv", "avi", "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus",
        "jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "pdf", "zip",
    ]

    public static func looksLikeFile(_ link: String) -> Bool {
        guard let url = URL(string: link) else { return false }
        return mediaExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isStream(_ url: URL) -> Bool {
        ["m3u8", "mpd"].contains(url.pathExtension.lowercased())
    }

    /// Pregunta al servidor qué es (sin bajar todo). `nil` si no es un archivo de medios.
    public static func mediaContentType(of url: URL, referer: String? = nil) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() else { return nil }
        let isMedia = ["video/", "audio/", "image/", "application/pdf", "application/zip"].contains { type.hasPrefix($0) }
            || (type.hasPrefix("application/octet-stream") && mediaExtensions.contains(url.pathExtension.lowercased()))
        return isMedia ? type : nil
    }

    public static func download(
        _ url: URL, to directory: URL, preferredName: String? = nil, referer: String? = nil,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }

        let tracker = TaskTracker()
        let poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                if let task = tracker.task, task.countOfBytesExpectedToReceive > 0 {
                    onProgress(Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive))
                }
            }
        }
        defer { poller.cancel() }

        let (tmp, response) = try await URLSession.shared.download(for: request, delegate: tracker)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        let name = preferredName ?? response.suggestedFilename ?? url.lastPathComponent
        let target = uniqueURL(in: directory, name: sanitize(name.isEmpty ? "descarga" : name))
        try FileManager.default.moveItem(at: tmp, to: target)
        return target
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return String(cleaned.prefix(180))
    }

    static func uniqueURL(in directory: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

private final class TaskTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _task: URLSessionTask?
    var task: URLSessionTask? { lock.withLock { _task } }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { _task = task }
    }
}

// MARK: - Streams HLS/DASH con ffmpeg

public enum StreamDownloader {
    public static func download(
        _ url: URL, to directory: URL, name: String, mode: MediaMode, audioFormat: AudioFormat,
        referer: String?, ffmpeg: URL, runner: ProcessRunner
    ) async throws -> URL {
        let ext = mode == .audio ? audioFormat.rawValue : "mp4"
        let target = DirectDownloader.uniqueURL(in: directory, name: DirectDownloader.sanitize(name) + "." + ext)
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-user_agent", browserUserAgent]
        if let referer { args += ["-headers", "Referer: \(referer)\r\n"] }
        args += ["-i", url.absoluteString]
        args += mode == .audio ? ["-vn"] + (audioFormat == .mp3 ? ["-q:a", "0"] : ["-c:a", "aac", "-b:a", "192k"])
                               : ["-c", "copy", "-bsf:a", "aac_adtstoasc", "-movflags", "+faststart"]
        args.append(target.path)
        let result = await runner.run(executable: ffmpeg, arguments: args)
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: target.path) else {
            try? FileManager.default.removeItem(at: target)
            throw URLError(.cannotDecodeContentData, userInfo: [NSLocalizedDescriptionKey: "ffmpeg: " + (result.output.split(separator: "\n").last.map(String.init) ?? "error")])
        }
        return target
    }
}

// MARK: - gallery-dl (imágenes, galerías, carruseles)

public enum GalleryDL {
    /// gallery-dl imprime la ruta de cada archivo bajado (o "# ruta" si ya existía).
    public static func parseFile(line: String) -> URL? {
        var l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("# ") { l.removeFirst(2) }
        guard l.hasPrefix("/"), FileManager.default.fileExists(atPath: l) else { return nil }
        return URL(fileURLWithPath: l)
    }

    public static func arguments(url: String, destination: URL, cookies: Browser?) -> [String] {
        var args = ["-D", destination.path, "--no-colors"]
        if let cookies { args += ["--cookies-from-browser", cookies.rawValue] }
        args += ["--", url]
        return args
    }
}

// MARK: - Leer el HTML de la página

public enum HTMLScraper {
    public struct Found: Sendable, Equatable {
        public var videos: [URL]
        public var images: [URL]
        public var title: String?
    }

    public static func scrape(_ pageURL: URL) async throws -> Found {
        var request = URLRequest(url: pageURL, timeoutInterval: 20)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("es,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parse(html: html, base: pageURL)
    }

    public static func parse(html: String, base: URL) -> Found {
        var videos: [String] = []
        var images: [String] = []

        // <meta property="og:video" content="…"> (en cualquier orden de atributos)
        for tag in matches(#"<meta\b[^>]*>"#, in: html) {
            guard let key = attr("property", in: tag) ?? attr("name", in: tag), let content = attr("content", in: tag) else { continue }
            switch key.lowercased() {
            case "og:video", "og:video:url", "og:video:secure_url", "twitter:player:stream": videos.append(content)
            case "og:image", "og:image:url", "og:image:secure_url", "twitter:image": images.append(content)
            default: break
            }
        }
        // <video src>, <source src>
        for tag in matches(#"<(?:video|source)\b[^>]*>"#, in: html) {
            if let src = attr("src", in: tag) { videos.append(src) }
        }
        // JSON-LD "contentUrl": "…"
        videos += captures(#""contentUrl"\s*:\s*"([^"]+)""#, in: html)
        // Cualquier .m3u8/.mp4 suelto en el código (reproductores en JavaScript)
        videos += matches(#"https?:\\?/\\?/[^"'\s<>]+?\.(?:m3u8|mp4)(?:\?[^"'\s<>]*)?"#, in: html)

        let title = captures(#"<meta\b[^>]*property=["']og:title["'][^>]*content=["']([^"']+)"#, in: html).first
            ?? captures(#"<title[^>]*>([^<]+)</title>"#, in: html).first

        return Found(videos: resolve(videos, base: base), images: resolve(images, base: base), title: title.map(decodeEntities))
    }

    private static func resolve(_ list: [String], base: URL) -> [URL] {
        var seen = Set<String>()
        return list.compactMap { raw -> URL? in
            let cleaned = decodeEntities(raw.replacingOccurrences(of: "\\/", with: "/"))
            guard !cleaned.hasPrefix("blob:"), !cleaned.hasPrefix("data:"),
                  let url = URL(string: cleaned, relativeTo: base)?.absoluteURL,
                  url.scheme?.hasPrefix("http") == true, seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    private static func attr(_ name: String, in tag: String) -> String? {
        captures(#"\b"# + name + #"\s*=\s*["']([^"']*)["']"#, in: tag).first
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    static func captures(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            $0.numberOfRanges > 1 ? Range($0.range(at: 1), in: text).map { String(text[$0]) } : nil
        }
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&#x2F;", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
