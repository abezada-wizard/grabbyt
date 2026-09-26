import Foundation

/// Vista previa de un link (sin descargar): título, miniatura, duración y calidades.
public struct MediaPreview: Sendable, Equatable {
    public var title: String
    public var uploader: String?
    public var site: String?
    public var duration: Double?
    public var thumbnail: URL?
    public var heights: [Int]          // alturas disponibles, de mayor a menor
    public var entryCount: Int?        // si es una lista/galería

    public init(title: String, uploader: String? = nil, site: String? = nil, duration: Double? = nil,
                thumbnail: URL? = nil, heights: [Int] = [], entryCount: Int? = nil) {
        self.title = title
        self.uploader = uploader
        self.site = site
        self.duration = duration
        self.thumbnail = thumbnail
        self.heights = heights
        self.entryCount = entryCount
    }

    public var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Calidades que tiene sentido ofrecer para este video.
    public var qualities: [VideoQuality] {
        guard let top = heights.first else { return [.best] }
        return [.best] + VideoQuality.allCases.filter { q in
            q != .best && q.rawValue <= top && heights.contains { h in abs(h - q.rawValue) <= 20 }
        }
    }
}

public enum MediaProbe {
    public static func probe(_ link: String, tools: ToolManager = .shared, timeout: Double = 25) async -> MediaPreview? {
        guard let ytdlp = await tools.path(for: .ytdlp) else { return nil }
        let runner = ProcessRunner()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout))
            runner.cancel()
        }
        defer { watchdog.cancel() }
        let result = await withTaskCancellationHandler {
            await runner.run(
                executable: ytdlp,
                arguments: ["-J", "--no-playlist", "--no-warnings", "--flat-playlist", "--socket-timeout", "15", "--", link]
            )
        } onCancel: {
            runner.cancel()
        }
        guard result.exitCode == 0, !result.wasCancelled else { return nil }
        // -J imprime un solo JSON en una línea; tomamos la línea que empieza con "{".
        guard let jsonLine = result.output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("{") }),
              let data = jsonLine.data(using: .utf8) else { return nil }
        return parse(json: data)
    }

    static func parse(json data: Data) -> MediaPreview? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let formats = obj["formats"] as? [[String: Any]] ?? []
        let heights = Set(formats.compactMap { f -> Int? in
            guard (f["vcodec"] as? String) != "none" else { return nil }
            return f["height"] as? Int
        }).sorted(by: >)
        var thumb = (obj["thumbnail"] as? String).flatMap(URL.init(string:))
        if thumb == nil, let thumbs = obj["thumbnails"] as? [[String: Any]], let last = thumbs.last?["url"] as? String {
            thumb = URL(string: last)
        }
        let entries = (obj["entries"] as? [Any])?.count
        return MediaPreview(
            title: (obj["title"] as? String) ?? (obj["fulltitle"] as? String) ?? "Sin título",
            uploader: (obj["uploader"] as? String) ?? (obj["channel"] as? String),
            site: obj["extractor_key"] as? String,
            duration: obj["duration"] as? Double ?? (obj["duration"] as? Int).map(Double.init),
            thumbnail: thumb,
            heights: heights,
            entryCount: entries
        )
    }
}
