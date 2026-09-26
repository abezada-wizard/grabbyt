import Foundation

public enum Tool: String, CaseIterable, Sendable {
    case ytdlp = "yt-dlp"
    case ffmpeg
    case ffprobe
    case galleryDL = "gallery-dl"

    var versionArgs: [String] { self == .ytdlp || self == .galleryDL ? ["--version"] : ["-version"] }

    /// Si falta, ¿se puede usar la app igual? (gallery-dl solo se usa como fallback)
    public var isEssential: Bool { self == .ytdlp }
}

public struct ToolInfo: Sendable, Equatable {
    public var path: URL?
    public var version: String?
    public var managed: Bool   // copia propia de Grabbyt vs. Homebrew/sistema
}

public enum ToolError: LocalizedError {
    case allSourcesFailed(Tool, String)
    public var errorDescription: String? {
        switch self {
        case .allSourcesFailed(let tool, let detail): "No se pudo instalar \(tool.rawValue): \(detail)"
        }
    }
}

/// Instala, localiza y actualiza yt-dlp/ffmpeg/ffprobe en ~/Library/Application Support/Grabbyt/bin.
/// Si la descarga falla, usa las copias de Homebrew o del PATH como respaldo.
public actor ToolManager {
    public static let shared = ToolManager()

    public nonisolated let binDir: URL
    private let lastUpdateKey = "grabbyt.lastYtDlpUpdate"

    // Varias fuentes por herramienta: si una cae, se prueba la siguiente.
    private let sources: [Tool: [URL]] = [
        .ytdlp: [
            // Versión "en carpeta": arranca en ~0.2 s. La de un solo archivo se descomprime en cada uso (~6 s).
            URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip")!,
            URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!,
        ],
        .ffmpeg: [
            URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip")!,
            URL(string: "https://www.osxexperts.net/ffmpeg80arm.zip")!,
            URL(string: "https://www.osxexperts.net/ffmpeg71arm.zip")!,
        ],
        .ffprobe: [
            URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffprobe.zip")!,
            URL(string: "https://www.osxexperts.net/ffprobe80arm.zip")!,
            URL(string: "https://www.osxexperts.net/ffprobe71arm.zip")!,
        ],
        .galleryDL: [
            URL(string: "https://github.com/gdl-org/builds/releases/latest/download/gallery-dl_macos")!,
        ],
    ]

    private let fallbackDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    public init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        binDir = support.appendingPathComponent("Grabbyt/bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    }

    // MARK: - Localizar

    private var ytdlpDistDir: URL { binDir.appendingPathComponent("yt-dlp-dist", isDirectory: true) }

    /// Copia propia de Grabbyt, si existe.
    public func managedPath(for tool: Tool) -> URL? {
        var candidates = [binDir.appendingPathComponent(tool.rawValue)]
        if tool == .ytdlp { candidates.insert(ytdlpDistDir.appendingPathComponent("yt-dlp_macos"), at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func path(for tool: Tool) -> URL? {
        if let managed = managedPath(for: tool) { return managed }
        for dir in fallbackDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(tool.rawValue)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func info(for tool: Tool) async -> ToolInfo {
        guard let path = path(for: tool) else { return ToolInfo(path: nil, version: nil, managed: false) }
        let result = await ProcessRunner().run(executable: path, arguments: tool.versionArgs)
        let firstLine = result.output.split(whereSeparator: \.isNewline).first.map(String.init)
        var version = firstLine
        if tool == .ffmpeg || tool == .ffprobe, let line = firstLine {
            // "ffmpeg version 8.0 Copyright..." → "8.0"
            let parts = line.split(separator: " ")
            if parts.count > 2 { version = String(parts[2].split(separator: "-").first ?? parts[2]) }
        }
        return ToolInfo(path: path, version: result.exitCode == 0 ? version : nil, managed: path.path.hasPrefix(binDir.path))
    }

    public func missingTools() -> [Tool] {
        Tool.allCases.filter { path(for: $0) == nil }
    }

    /// Directorio donde está ffmpeg (para --ffmpeg-location).
    public func ffmpegLocation() -> URL? {
        path(for: .ffmpeg)?.deletingLastPathComponent()
    }

    // MARK: - Instalar

    /// Instala las herramientas que falten en la carpeta propia.
    public func installMissing(progress: @Sendable (String) -> Void) async throws {
        let ytdlpBundled = FileManager.default.isExecutableFile(atPath: ytdlpDistDir.appendingPathComponent("yt-dlp_macos").path)
        for tool in Tool.allCases where managedPath(for: tool) == nil || (tool == .ytdlp && !ytdlpBundled) {
            // Si ya hay una copia en Homebrew no bloqueamos el arranque por esta herramienta,
            // pero intentamos tener la propia igualmente.
            let hasFallback = path(for: tool) != nil
            progress("Descargando \(tool.rawValue)…")
            do {
                try await install(tool)
            } catch where hasFallback {
                progress("Usando \(tool.rawValue) del sistema")
            }
        }
    }

    public func install(_ tool: Tool) async throws {
        var lastError = "sin fuentes"
        for source in sources[tool] ?? [] {
            do {
                try await download(tool, from: source)
                return
            } catch {
                lastError = "\(source.host ?? source.absoluteString): \(error.localizedDescription)"
            }
        }
        throw ToolError.allSourcesFailed(tool, lastError)
    }

    private func download(_ tool: Tool, from url: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("Grabbyt/1.0", forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }

        let fm = FileManager.default
        if tool == .ytdlp, url.pathExtension == "zip" {
            try await installYtDlpBundle(zip: tmp)
            return
        }
        let destination = binDir.appendingPathComponent(tool.rawValue)
        let staging = binDir.appendingPathComponent(".\(tool.rawValue).new")
        try? fm.removeItem(at: staging)

        if url.pathExtension == "zip" {
            let unzipDir = fm.temporaryDirectory.appendingPathComponent("grabbyt-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: unzipDir) }
            let unzip = await ProcessRunner().run(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", tmp.path, unzipDir.path]
            )
            guard unzip.exitCode == 0 else { throw URLError(.cannotDecodeContentData) }
            guard let binary = findBinary(named: tool.rawValue, in: unzipDir) else {
                throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "El zip no contiene \(tool.rawValue)"])
            }
            try fm.moveItem(at: binary, to: staging)
        } else {
            try fm.moveItem(at: tmp, to: staging)
        }

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        _ = await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-d", "com.apple.quarantine", staging.path])

        // Verificar que realmente ejecuta antes de reemplazar la copia buena.
        let check = await ProcessRunner().run(executable: staging, arguments: tool.versionArgs)
        guard check.exitCode == 0 else {
            try? fm.removeItem(at: staging)
            throw URLError(.cannotOpenFile, userInfo: [NSLocalizedDescriptionKey: "El binario descargado no ejecuta"])
        }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    /// Descomprime la versión en carpeta de yt-dlp, la verifica y reemplaza la anterior.
    private func installYtDlpBundle(zip: URL) async throws {
        let fm = FileManager.default
        let staging = binDir.appendingPathComponent(".yt-dlp-dist.new", isDirectory: true)
        try? fm.removeItem(at: staging)
        let unzip = await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.path, staging.path])
        guard unzip.exitCode == 0, let exe = findBinary(named: "yt-dlp_macos", in: staging) else {
            try? fm.removeItem(at: staging)
            throw URLError(.cannotDecodeContentData, userInfo: [NSLocalizedDescriptionKey: "zip de yt-dlp inválido"])
        }
        // Dejar el ejecutable en la raíz de la carpeta (por si el zip trae una subcarpeta).
        let root = exe.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        _ = await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-dr", "com.apple.quarantine", root.path])
        // Primera ejecución: macOS revisa todos los archivos (~6 s). Mejor pagarlo aquí que en la primera descarga.
        let check = await ProcessRunner().run(executable: exe, arguments: ["--version"])
        guard check.exitCode == 0 else {
            try? fm.removeItem(at: staging)
            throw URLError(.cannotOpenFile, userInfo: [NSLocalizedDescriptionKey: "yt-dlp descargado no ejecuta"])
        }
        try? fm.removeItem(at: ytdlpDistDir)
        try fm.moveItem(at: root, to: ytdlpDistDir)
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: binDir.appendingPathComponent(Tool.ytdlp.rawValue))   // versión antigua de un archivo
    }

    private func findBinary(named name: String, in dir: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        return nil
    }

    // MARK: - Actualizar yt-dlp

    /// Actualiza yt-dlp si hay versión nueva (descarga la última de GitHub).
    /// Si varias descargas fallan a la vez, todas esperan la misma actualización.
    @discardableResult
    public func updateYtDlp(force: Bool = true) async -> Bool {
        if let running = updateTask { return await running.value }
        let last = UserDefaults.standard.double(forKey: lastUpdateKey)
        if !force, Date().timeIntervalSince1970 - last < 600 { return true }
        let task = Task { await performYtDlpUpdate() }
        updateTask = task
        let ok = await task.value
        updateTask = nil
        return ok
    }

    private var updateTask: Task<Bool, Never>?

    private func performYtDlpUpdate() async -> Bool {
        // ¿Hay versión nueva? Evita bajar ~40 MB si ya estamos al día.
        let current = await info(for: .ytdlp).version
        if let latest = await latestYtDlpVersion(), let current, latest == current, managedPath(for: .ytdlp) != nil {
            markUpdated()
            return true
        }
        do {
            try await install(.ytdlp)
            markUpdated()
            return true
        } catch {
            // Último recurso: auto-actualización de la versión de un archivo.
            if let single = managedPath(for: .ytdlp), single.lastPathComponent == Tool.ytdlp.rawValue {
                let result = await ProcessRunner().run(executable: single, arguments: ["-U"])
                if result.exitCode == 0 { markUpdated(); return true }
            }
            return false
        }
    }

    private func latestYtDlpVersion() async -> String? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!, timeoutInterval: 15)
        request.setValue("Grabbyt/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["tag_name"] as? String
    }

    /// yt-dlp: si pasó más de un día. gallery-dl: una vez por semana (cambia menos).
    public func updateYtDlpIfStale() async {
        let now = Date().timeIntervalSince1970
        if now - UserDefaults.standard.double(forKey: lastUpdateKey) > 24 * 3600 {
            await updateYtDlp(force: true)
        }
        let galleryKey = "grabbyt.lastGalleryDLUpdate"
        if now - UserDefaults.standard.double(forKey: galleryKey) > 7 * 24 * 3600 {
            if (try? await install(.galleryDL)) != nil {
                UserDefaults.standard.set(now, forKey: galleryKey)
            }
        }
    }

    private func markUpdated() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastUpdateKey)
    }
}
