import AppKit
import SwiftUI

/// Revisa si hay una versión nueva de Grabbyt en GitHub Releases.
/// El repo sale de la clave `GrabbytRepository` del Info.plist (la pone scripts/build-app.sh).
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        var version: String
        var page: URL
    }

    @Published var available: Release?

    static var repository: String? {
        let repo = Bundle.main.object(forInfoDictionaryKey: "GrabbytRepository") as? String
        return repo?.isEmpty == false ? repo : nil
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func check() async {
        guard let repo = Self.repository,
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Grabbyt/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if Self.isNewer(latest, than: Self.currentVersion),
           UserDefaults.standard.string(forKey: "dismissedUpdate") != latest {
            available = Release(version: latest, page: page)
        }
    }

    func dismiss() {
        if let version = available?.version { UserDefaults.standard.set(version, forKey: "dismissedUpdate") }
        available = nil
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
