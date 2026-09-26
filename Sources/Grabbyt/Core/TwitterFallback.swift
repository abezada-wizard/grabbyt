import Foundation

/// Fallback para X/Twitter cuando yt-dlp falla: pregunta a las APIs públicas de fxtwitter/vxtwitter
/// (las que usan los "embeds" de Discord). Suelen entregar videos de tweets sensibles sin sesión, y también fotos.
public enum TwitterFallback {
    public struct Media: Equatable, Sendable {
        public enum Kind: String, Sendable { case video, gif, photo }
        public var kind: Kind
        public var url: URL
    }

    private static let hosts = ["twitter.com", "x.com", "fxtwitter.com", "vxtwitter.com", "fixupx.com", "fixvx.com", "nitter.net"]

    /// "https://x.com/usuario/status/123?s=20" → ("usuario", "123")
    public static func tweetID(from link: String) -> String? {
        guard let url = URL(string: link), let host = url.host?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host.replacingOccurrences(of: "mobile.", with: "")
        guard hosts.contains(bare) else { return nil }
        let parts = url.pathComponents
        guard let i = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }), i + 1 < parts.count else { return nil }
        let id = parts[i + 1]
        return id.allSatisfy(\.isNumber) ? id : nil
    }

    public static func fetchMedia(tweetID id: String) async throws -> (author: String, media: [Media]) {
        var lastError: Error = URLError(.resourceUnavailable)
        for fetch in [fetchFx, fetchVx] {
            do {
                let result = try await fetch(id)
                if !result.media.isEmpty { return result }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // api.fxtwitter.com/status/<id> → tweet.media.all[] { type, url }
    private static func fetchFx(_ id: String) async throws -> (author: String, media: [Media]) {
        let json = try await getJSON("https://api.fxtwitter.com/status/\(id)")
        guard let tweet = json["tweet"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let author = (tweet["author"] as? [String: Any])?["screen_name"] as? String ?? "tweet"
        let all = ((tweet["media"] as? [String: Any])?["all"] as? [[String: Any]]) ?? []
        let media = all.compactMap { item -> Media? in
            guard let type = item["type"] as? String, let s = item["url"] as? String, let url = URL(string: s) else { return nil }
            return Media(kind: Media.Kind(rawValue: type) ?? .video, url: url)
        }
        return (author, media)
    }

    // api.vxtwitter.com/Twitter/status/<id> → media_extended[] { type, url }
    private static func fetchVx(_ id: String) async throws -> (author: String, media: [Media]) {
        let json = try await getJSON("https://api.vxtwitter.com/Twitter/status/\(id)")
        let author = json["user_screen_name"] as? String ?? "tweet"
        let items = (json["media_extended"] as? [[String: Any]]) ?? []
        let media = items.compactMap { item -> Media? in
            guard let type = item["type"] as? String, let s = item["url"] as? String, let url = URL(string: s) else { return nil }
            return Media(kind: type == "image" ? .photo : (Media.Kind(rawValue: type) ?? .video), url: url)
        }
        return (author, media)
    }

    private static func getJSON(_ string: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: string)!, timeoutInterval: 20)
        request.setValue("Grabbyt/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return json
    }

    /// Descarga los archivos a `destination`. En modo audio solo baja videos y les extrae el audio con ffmpeg.
    public static func download(
        tweetID id: String, mode: MediaMode, destination: URL, ffmpeg: URL?,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> [URL] {
        let (author, allMedia) = try await fetchMedia(tweetID: id)
        let media = mode == .audio ? allMedia.filter { $0.kind != .photo } : allMedia
        guard !media.isEmpty else { throw URLError(.resourceUnavailable) }

        var saved: [URL] = []
        let fm = FileManager.default
        for (index, item) in media.enumerated() {
            onStatus("Descargando \(index + 1)/\(media.count) vía fxtwitter…")
            var source = item.url
            if item.kind == .photo, var comps = URLComponents(url: source, resolvingAgainstBaseURL: false) {
                comps.queryItems = [URLQueryItem(name: "name", value: "orig")]   // máxima resolución
                source = comps.url ?? source
            }
            let (tmp, response) = try await URLSession.shared.download(from: source)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            let ext = item.url.pathExtension.isEmpty ? (item.kind == .photo ? "jpg" : "mp4") : item.url.pathExtension
            let suffix = media.count > 1 ? " \(index + 1)" : ""
            var target = destination.appendingPathComponent("\(author) - \(id)\(suffix).\(ext)")
            try? fm.removeItem(at: target)
            try fm.moveItem(at: tmp, to: target)

            if mode == .audio, let ffmpeg {
                onStatus("Extrayendo audio…")
                let mp3 = target.deletingPathExtension().appendingPathExtension("mp3")
                let result = await ProcessRunner().run(executable: ffmpeg, arguments: ["-y", "-i", target.path, "-vn", "-q:a", "0", mp3.path])
                if result.exitCode == 0 {
                    try? fm.removeItem(at: target)
                    target = mp3
                }
            }
            saved.append(target)
        }
        return saved
    }
}
