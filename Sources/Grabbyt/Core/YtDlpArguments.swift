import Foundation

/// Construye argumentos de yt-dlp y parsea las líneas marcadas que le pedimos imprimir.
public enum YtDlpArguments {
    static let progressTag = "GRBP|"
    static let titleTag = "GRBT|"
    static let fileTag = "GRBF|"
    static let postprocessTag = "GRBS|"

    public enum ParsedLine: Equatable {
        case progress(Double?, String?, String?)
        case title(String)
        case file(String)
    }

    public static func build(request: DownloadRequest, config: AttemptConfig, ffmpegDir: URL?) -> [String] {
        var args: [String] = [
            "--newline", "--color", "never",
            "--no-playlist", "--no-mtime",
            "--retries", "3", "--fragment-retries", "5", "--socket-timeout", "20",
            "--concurrent-fragments", "4",
            "-P", request.destination.path,
            "-o", "%(title).100B [%(id)s].%(ext)s",
            // --print implica --quiet; --progress y --no-simulate lo compensan.
            "--no-simulate", "--progress",
            "--print", "before_dl:\(titleTag)%(title)s",
            "--print", "after_move:\(fileTag)%(filepath)s",
            "--progress-template", "download:\(progressTag)%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--progress-template", "postprocess:\(postprocessTag)%(progress.postprocessor)s",
        ]

        let h = request.quality == .best ? "" : "[height<=\(request.quality.rawValue)]"
        switch (request.mode, config.mergeFormats) {
        case (.video, true), (.images, true):
            // Prioriza H.264/AAC para que el archivo abra en QuickTime/Fotos.
            var sort = "vcodec:h264,res,acodec:m4a"
            if request.quality != .best { sort = "res:\(request.quality.rawValue)," + sort }
            args += ["-f", "bv*\(h)+ba/b\(h)/bv*+ba/b", "-S", sort, "--merge-output-format", "mp4"]
        case (.video, false), (.images, false):
            args += ["-f", "b[ext=mp4]\(h)/b\(h)/b"]
        case (.audio, true):
            args += ["-f", "ba/b", "-x", "--audio-format", request.audioFormat.rawValue, "--audio-quality", "0", "--embed-metadata"]
        case (.audio, false):
            args += ["-f", "ba[ext=m4a]/ba/b"]
        }

        if let ffmpegDir { args += ["--ffmpeg-location", ffmpegDir.path] }
        if let browser = config.cookies { args += ["--cookies-from-browser", browser.rawValue] }
        if config.impersonate { args += ["--impersonate", "chrome"] }
        if config.altClient { args += ["--extractor-args", "youtube:player_client=tv,web_safari,mweb,android_vr"] }

        args += ["--", request.url]
        return args
    }

    public static func parse(line: String) -> ParsedLine? {
        if line.hasPrefix(progressTag) {
            let parts = line.dropFirst(progressTag.count).split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let percent = parts.first.flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }.map { min(max($0 / 100, 0), 1) }
            let speed = parts.count > 1 ? clean(parts[1]) : nil
            let eta = parts.count > 2 ? clean(parts[2]) : nil
            return .progress(percent, speed, eta)
        }
        if line.hasPrefix(titleTag) { return .title(String(line.dropFirst(titleTag.count))) }
        if line.hasPrefix(fileTag) { return .file(String(line.dropFirst(fileTag.count))) }
        if line.hasPrefix(postprocessTag) {
            // Lo mostramos como progreso indeterminado ("procesando").
            return .progress(nil, nil, nil)
        }
        return nil
    }

    private static func clean(_ s: String) -> String? {
        let v = s.trimmingCharacters(in: .whitespaces)
        return v.isEmpty || v == "NA" || v.lowercased().contains("unknown") ? nil : v
    }

    static func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=,+".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
