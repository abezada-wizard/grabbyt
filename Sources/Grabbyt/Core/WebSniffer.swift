import AppKit
import WebKit

/// Último recurso: carga la página en un WebKit invisible, intenta reproducir los videos en silencio
/// y anota las URLs de medios que pide el reproductor (m3u8/mp4/mpd), aunque las arme JavaScript.
@MainActor
public final class WebSniffer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    public struct Result: Sendable {
        public var media: [URL]
        public var title: String?
    }

    private var webView: WKWebView?
    private var window: NSWindow?
    private var found: [String] = []

    private static let hook = """
    (function() {
      const report = (u) => { try { if (u) window.webkit.messageHandlers.grabbyt.postMessage(String(u)); } catch (e) {} };
      const origFetch = window.fetch;
      window.fetch = function(input, init) { report(input && input.url ? input.url : input); return origFetch.apply(this, arguments); };
      const origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) { report(url); return origOpen.apply(this, arguments); };
    })();
    """

    private static let poll = """
    (function() {
      const out = [];
      document.querySelectorAll('video, audio, source').forEach(v => { out.push(v.currentSrc || v.src); });
      document.querySelectorAll('video').forEach(v => { v.muted = true; const p = v.play(); if (p) p.catch(() => {}); });
      performance.getEntriesByType('resource').forEach(e => out.push(e.name));
      return out.filter(Boolean);
    })();
    """

    private static let adHosts = ["doubleclick", "googlesyndication", "imasdk", "googleads", "adservice", "amazon-adsystem", "adnxs"]

    public static func sniff(_ url: URL, timeout: Double = 25) async -> Result {
        let sniffer = WebSniffer()
        return await sniffer.run(url, timeout: timeout)
    }

    private func run(_ url: URL, timeout: Double) async -> Result {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "grabbyt")
        config.userContentController.addUserScript(WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let web = WKWebView(frame: frame, configuration: config)
        web.customUserAgent = browserUserAgent
        web.navigationDelegate = self
        // Una ventana invisible fuera de pantalla: sin ventana, WebKit frena timers y reproducción.
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.contentView = web
        win.orderFrontRegardless()
        webView = web
        window = win
        defer { tearDown() }

        web.load(URLRequest(url: url))

        let deadline = Date().addingTimeInterval(timeout)
        var firstHit: Date?
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { break }
            if let list = try? await web.evaluateJavaScript(Self.poll) as? [String] {
                list.forEach(record)
            }
            if !candidates().isEmpty {
                firstHit = firstHit ?? Date()
                // Esperar un poco más: a veces primero sale un anuncio o una calidad baja.
                if Date().timeIntervalSince(firstHit!) > 2.5 { break }
            }
        }
        return Result(media: candidates(), title: web.title)
    }

    private func record(_ raw: String) {
        if !found.contains(raw) { found.append(raw) }
    }

    /// Ordena: m3u8 "master" > m3u8 > mpd > mp4. Descarta anuncios, segmentos .ts y blobs.
    func candidates() -> [URL] {
        let urls = found.compactMap { URL(string: $0) }.filter { url in
            guard url.scheme?.hasPrefix("http") == true, let host = url.host?.lowercased() else { return false }
            return !Self.adHosts.contains(where: host.contains)
        }
        func rank(_ url: URL) -> Int? {
            let s = url.absoluteString.lowercased()
            let path = url.path.lowercased()
            if path.hasSuffix(".m3u8") || s.contains(".m3u8?") { return s.contains("master") ? 0 : 1 }
            if path.hasSuffix(".mpd") { return 2 }
            if path.hasSuffix(".mp4") || path.hasSuffix(".webm") || path.hasSuffix(".mov") || s.contains("mime=video") { return 3 }
            if path.hasSuffix(".mp3") || path.hasSuffix(".m4a") { return 4 }
            return nil
        }
        return urls.compactMap { url in rank(url).map { (url, $0) } }
            .enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map(\.element.0)
    }

    private func tearDown() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "grabbyt")
        window?.orderOut(nil)
        window?.contentView = nil
        webView = nil
        window = nil
    }

    public nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            if let s = message.body as? String, let base = webView?.url, let url = URL(string: s, relativeTo: base) {
                record(url.absoluteString)
            }
        }
    }
}
