import Foundation

public enum Browser: String, CaseIterable, Sendable, Identifiable {
    case chrome, brave, firefox, edge, vivaldi, opera, safari

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .firefox: "Firefox"
        case .edge: "Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .safari: "Safari"
        }
    }

    var appPaths: [String] {
        switch self {
        case .chrome: ["/Applications/Google Chrome.app"]
        case .brave: ["/Applications/Brave Browser.app"]
        case .firefox: ["/Applications/Firefox.app"]
        case .edge: ["/Applications/Microsoft Edge.app"]
        case .vivaldi: ["/Applications/Vivaldi.app"]
        case .opera: ["/Applications/Opera.app"]
        case .safari: ["/Applications/Safari.app", "/System/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"]
        }
    }

    /// Dónde guarda cada navegador sus cookies (relativo a ~/Library).
    var cookieStores: [String] {
        switch self {
        case .chrome: ["Application Support/Google/Chrome"]
        case .brave: ["Application Support/BraveSoftware/Brave-Browser"]
        case .edge: ["Application Support/Microsoft Edge"]
        case .vivaldi: ["Application Support/Vivaldi"]
        case .opera: ["Application Support/com.operasoftware.Opera"]
        case .firefox: ["Application Support/Firefox/Profiles"]
        case .safari: ["Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies", "Cookies/Cookies.binarycookies"]
        }
    }

    /// Navegadores instalados (aunque no tengan cookies legibles), para el selector de Ajustes.
    public static func installed() -> [Browser] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        return allCases.filter { browser in
            browser == .safari || browser.appPaths.contains { fm.fileExists(atPath: $0) || fm.fileExists(atPath: home + $0) }
        }
    }

    /// Navegadores cuyas cookies se pueden leer de verdad. Safari solo aparece si la app tiene "Acceso total al disco".
    public static func withReadableCookies() -> [Browser] {
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        return installed().filter { browser in
            browser.cookieStores.contains { relative in
                let path = library + "/" + relative
                if browser == .safari { return fm.isReadableFile(atPath: path) && (try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))) != nil }
                return containsCookieDB(at: URL(fileURLWithPath: path))
            }
        }
    }

    /// Busca "Cookies" (Chromium: Default/Network/Cookies) o "cookies.sqlite" (Firefox) sin bajar más de 3 niveles.
    private static func containsCookieDB(at root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        while let url = enumerator.nextObject() as? URL {
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            let name = url.lastPathComponent
            if name == "Cookies" || name == "cookies.sqlite" { return true }
        }
        return false
    }
}

public enum MediaMode: String, Sendable, CaseIterable, Identifiable, Codable {
    case video, audio, images
    public var id: String { rawValue }
}

/// Altura máxima del video. `best` = sin límite.
public enum VideoQuality: Int, Sendable, CaseIterable, Identifiable, Codable {
    case best = 0, p2160 = 2160, p1440 = 1440, p1080 = 1080, p720 = 720, p480 = 480, p360 = 360
    public var id: Int { rawValue }
    public var label: String { self == .best ? "Mejor" : "\(rawValue)p" }
}

public enum AudioFormat: String, Sendable, CaseIterable, Identifiable, Codable {
    case mp3, m4a
    public var id: String { rawValue }
}

/// Configuración de un intento de descarga. La cadena de fallbacks va mutando esto.
public struct AttemptConfig: Hashable, Sendable {
    public var mergeFormats: Bool        // bv*+ba con ffmpeg vs. un solo archivo
    public var cookies: Browser?
    public var impersonate: Bool
    public var altClient: Bool           // YouTube: otros "player clients" (esquiva bloqueos de bot/formatos)
    public var updateFirst: Bool         // actualizar yt-dlp antes de este intento
    public var waitSeconds: Int          // esperar antes (rate limits / red)

    public init(mergeFormats: Bool, cookies: Browser? = nil, impersonate: Bool = false, altClient: Bool = false, updateFirst: Bool = false, waitSeconds: Int = 0) {
        self.mergeFormats = mergeFormats
        self.altClient = altClient
        self.cookies = cookies
        self.impersonate = impersonate
        self.updateFirst = updateFirst
        self.waitSeconds = waitSeconds
    }

    /// Identidad del intento sin los pasos previos (actualizar/esperar), para no repetir el mismo intento.
    var signature: String { "\(mergeFormats)|\(cookies?.rawValue ?? "-")|\(impersonate)|\(altClient)" }

    public var summary: String {
        var parts = [mergeFormats ? "mejor calidad" : "archivo único"]
        if let cookies { parts.append("cookies de \(cookies.displayName)") }
        if impersonate { parts.append("imitando Chrome") }
        if altClient { parts.append("cliente alternativo") }
        var prefix = ""
        if updateFirst { prefix += "actualizar yt-dlp → " }
        if waitSeconds > 0 { prefix += "esperar \(waitSeconds)s → " }
        return prefix + parts.joined(separator: " + ")
    }
}

/// Decide el siguiente intento según el tipo de error. No prueba todo a ciegas:
/// cada fallo tiene su propia lista ordenada de remedios.
public struct AttemptPlanner: Sendable {
    public let browsers: [Browser]
    public let maxAttempts: Int
    public let isYouTube: Bool
    private(set) var tried: Set<String> = []
    private(set) var failedCookieBrowsers: Set<Browser> = []
    private(set) var didUpdate = false
    private(set) var waits = 0
    public private(set) var attempts = 0

    /// - Parameter preferredBrowser: si el usuario eligió uno en Ajustes, va primero.
    public init(installedBrowsers: [Browser], preferredBrowser: Browser?, isYouTube: Bool = false, maxAttempts: Int = 10) {
        self.isYouTube = isYouTube
        var list = installedBrowsers
        if let preferred = preferredBrowser {
            list.removeAll { $0 == preferred }
            list.insert(preferred, at: 0)
        }
        self.browsers = list
        self.maxAttempts = maxAttempts
    }

    public mutating func first(hasFfmpeg: Bool) -> AttemptConfig {
        let config = AttemptConfig(mergeFormats: hasFfmpeg)
        record(config)
        return config
    }

    /// Devuelve el siguiente intento o `nil` si ya no hay nada razonable que probar.
    public mutating func next(after failure: FailureKind, previous: AttemptConfig, canUpdate: Bool) -> AttemptConfig? {
        guard attempts < maxAttempts else { return nil }
        if failure == .cookieFailure, let browser = previous.cookies {
            failedCookieBrowsers.insert(browser)
        }

        var base = previous
        base.updateFirst = false
        base.waitSeconds = 0

        for remedy in remedies(for: failure) {
            if let candidate = apply(remedy, to: base, canUpdate: canUpdate) {
                record(candidate)
                return candidate
            }
        }
        return nil
    }

    // MARK: - Remedios

    enum Remedy {
        case singleFile, update, cookies, nextCookies, dropCookies, impersonate, altClient, wait(Int)
    }

    func remedies(for failure: FailureKind) -> [Remedy] {
        let base = baseRemedies(for: failure)
        // En YouTube, cambiar de "player client" arregla muchos bloqueos de bot y formatos faltantes.
        if isYouTube, [.loginRequired, .blocked, .formatUnavailable, .extractorBroken, .unknown, .rateLimited].contains(failure) {
            return [.altClient] + base
        }
        return base
    }

    func baseRemedies(for failure: FailureKind) -> [Remedy] {
        switch failure {
        case .ffmpegMissing, .formatUnavailable:
            [.singleFile, .update, .impersonate]
        case .extractorBroken:
            [.update, .impersonate, .cookies, .singleFile]
        case .loginRequired:
            [.cookies, .nextCookies, .impersonate, .update]
        case .cookieFailure:
            [.nextCookies, .dropCookies]
        case .blocked:
            [.impersonate, .cookies, .nextCookies, .update, .singleFile]
        case .rateLimited:
            [.wait(15), .impersonate, .cookies, .wait(45)]
        case .network:
            [.wait(5), .wait(15)]
        case .notFound, .noMedia:
            [.update, .cookies]   // a veces "no existe" = hace falta sesión o el extractor está viejo
        case .unknown:
            [.singleFile, .update, .impersonate, .cookies, .nextCookies]
        case .geoBlocked, .unsupportedURL, .imagesOnly:
            []   // imagesOnly lo resuelve la etapa de imágenes del post
        }
    }

    private mutating func apply(_ remedy: Remedy, to base: AttemptConfig, canUpdate: Bool) -> AttemptConfig? {
        var c = base
        switch remedy {
        case .singleFile:
            guard c.mergeFormats else { return nil }
            c.mergeFormats = false
        case .update:
            guard canUpdate, !didUpdate else { return nil }
            c.updateFirst = true
            didUpdate = true
            return c   // mismo intento, pero con yt-dlp nuevo: no se filtra por "ya probado"
        case .cookies:
            guard c.cookies == nil, let b = nextBrowser(after: nil) else { return nil }
            c.cookies = b
        case .nextCookies:
            guard let b = nextBrowser(after: c.cookies) else { return nil }
            c.cookies = b
        case .dropCookies:
            guard c.cookies != nil else { return nil }
            c.cookies = nil
            if !c.impersonate { c.impersonate = true }
        case .impersonate:
            guard !c.impersonate else { return nil }
            c.impersonate = true
        case .altClient:
            guard !c.altClient else { return nil }
            c.altClient = true
        case .wait(let seconds):
            guard waits < 2 else { return nil }
            waits += 1
            c.waitSeconds = seconds
            return c
        }
        return tried.contains(c.signature) ? nil : c
    }

    private func nextBrowser(after current: Browser?) -> Browser? {
        let start = current.flatMap { browsers.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        return browsers.dropFirst(start).first { !failedCookieBrowsers.contains($0) }
    }

    private mutating func record(_ config: AttemptConfig) {
        tried.insert(config.signature)
        attempts += 1
    }
}
