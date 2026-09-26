import Foundation

public enum LinkParser {
    /// Saca el primer link http(s) de un texto pegado (sirve con "mira esto https://x.com/..." o links sin esquema).
    public static func firstURL(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            for match in detector.matches(in: trimmed, range: range) {
                guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
                // Sin esquema escrito ("x.com/..."), el detector pone http://: preferimos https.
                let written = Range(match.range, in: trimmed).map { trimmed[$0].lowercased() } ?? ""
                if !written.hasPrefix("http"), var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    comps.scheme = "https"
                    return comps.string ?? url.absoluteString
                }
                return url.absoluteString
            }
        }
        // "x.com/usuario/status/123" sin esquema
        if !trimmed.contains(" "), trimmed.contains("."), let url = URL(string: "https://" + trimmed), url.host != nil {
            return url.absoluteString
        }
        return nil
    }

    /// Nombre corto del sitio para mostrar en la lista ("x.com", "youtube.com").
    public static func siteName(for link: String) -> String {
        guard let host = URL(string: link)?.host?.lowercased() else { return link }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
