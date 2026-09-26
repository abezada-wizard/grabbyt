import Foundation

/// Categorías de fallo que devuelve yt-dlp. Cada una tiene una estrategia de recuperación distinta.
public enum FailureKind: String, Sendable, CaseIterable {
    case ffmpegMissing
    case formatUnavailable
    case loginRequired
    case cookieFailure
    case rateLimited
    case blocked
    case geoBlocked
    case notFound
    case unsupportedURL
    case noMedia
    case extractorBroken
    case network
    case unknown

    /// Mensaje para el usuario cuando ya no quedan estrategias.
    public var userMessage: String {
        switch self {
        case .ffmpegMissing: "Falta ffmpeg para unir audio y video. Reinstala las herramientas en Ajustes."
        case .formatUnavailable: "El formato pedido no está disponible."
        case .loginRequired: "Este contenido requiere iniciar sesión. Inicia sesión en tu navegador y elige ese navegador en Ajustes."
        case .cookieFailure: "No se pudieron leer las cookies del navegador. Para Safari, dale a Grabbyt 'Acceso total al disco' en Ajustes del Sistema."
        case .rateLimited: "El sitio está limitando las descargas (demasiadas peticiones). Espera unos minutos."
        case .blocked: "El sitio bloqueó la descarga (403 / anti-bots)."
        case .geoBlocked: "Este contenido no está disponible en tu país."
        case .notFound: "El contenido no existe o fue eliminado."
        case .unsupportedURL: "Este sitio aún no está soportado por yt-dlp."
        case .noMedia: "No se encontró video en ese link (puede que solo tenga imágenes o texto)."
        case .extractorBroken: "El extractor de este sitio parece roto, incluso tras actualizar yt-dlp."
        case .network: "Problema de red. Revisa tu conexión."
        case .unknown: "Error desconocido. Revisa el registro para más detalles."
        }
    }
}

public enum ErrorClassifier {
    // El orden importa: la primera coincidencia gana.
    private static let rules: [(FailureKind, [String])] = [
        (.cookieFailure, [
            "could not find chrome cookies", "could not find firefox cookies", "could not find brave cookies",
            "cookies database", "failed to decrypt", "cannot decrypt", "cookies from browser",
            "binarycookies", "operation not permitted", "keyring", "could not copy",
        ]),
        (.ffmpegMissing, [
            "ffmpeg is not installed", "ffmpeg not found", "ffprobe and ffmpeg not found",
            "you have requested merging of multiple formats but ffmpeg",
        ]),
        (.formatUnavailable, ["requested format is not available", "requested format not available"]),
        (.geoBlocked, ["available in your country", "geo restrict", "geo-restrict", "not available from your location"]),
        (.rateLimited, ["http error 429", "too many requests", "rate-limit reached", "rate limit"]),
        (.loginRequired, [
            "login required", "log in to", "sign in to confirm", "sign in to view", "use --cookies",
            "--cookies-from-browser", "private video", "this video is private", "age-restricted",
            "confirm your age", "inappropriate for some users", "nsfw", "requires authentication",
            "authentication is required", "you need to log in", "members-only", "only available for registered users",
            "sensitive", "video #",   // X: "Video #1 is unavailable" = contenido sensible o con restricción
        ]),
        (.blocked, [
            "http error 403", "forbidden", "cloudflare", "captcha", "--impersonate", "impersonat",
            "anti-bot", "blocked", "access denied",
        ]),
        (.unsupportedURL, ["unsupported url"]),
        (.noMedia, [
            "no video could be found", "there's no video", "no video in this", "no media found",
            "no video formats found", "does not contain a video", "no formats found",
        ]),
        (.notFound, [
            "http error 404", "does not exist", "video unavailable", "video is unavailable", "is not available", "this content isn't available", "has been removed", "tweet is unavailable",
            "post is unavailable", "not found", "been deleted", "no longer available",
        ]),
        (.network, [
            "unable to connect", "timed out", "nodename nor servname", "name or service not known",
            "network is unreachable", "connection reset", "connection refused", "temporary failure in name resolution",
            "urlopen error", "ssl:",
        ]),
        (.extractorBroken, [
            "unable to extract", "please report this issue", "confirm you are on the latest version",
            "unable to download json metadata", "unable to download webpage", "keyerror", "typeerror",
            "extractorerror", "unexpected response", "failed to parse",
        ]),
    ]

    /// Clasifica la salida de error de yt-dlp. Solo mira las líneas de ERROR si las hay, para no confundirse con WARNINGs.
    public static func classify(_ output: String) -> FailureKind {
        let lines = output.lowercased().split(whereSeparator: \.isNewline)
        let errorLines = lines.filter { $0.contains("error") }
        let haystack = (errorLines.isEmpty ? lines : errorLines).joined(separator: "\n")
        for (kind, needles) in rules where needles.contains(where: haystack.contains) {
            return kind
        }
        return .unknown
    }
}
