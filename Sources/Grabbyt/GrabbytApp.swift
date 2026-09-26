import AppKit
import GrabbytCore
import SwiftUI

@main
struct GrabbytApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var tools = ToolsModel.shared
    @StateObject private var updates = UpdateChecker()
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("Grabbyt", id: "main") {
            ContentView()
                .environmentObject(downloads)
                .environmentObject(tools)
                .environmentObject(updates)
                .frame(minWidth: 560, minHeight: 480)
                .task {
                    await tools.bootstrap()
                    await updates.check()
                }
        }
        .defaultSize(width: 640, height: 680)
        .windowResizability(.contentMinSize)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .environmentObject(downloads)
                .environmentObject(tools)
        } label: {
            Image(systemName: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(downloads)
                .environmentObject(tools)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Necesario cuando se corre con `swift run` (sin .app): que sea una app normal con ventana y Dock.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Notifier.requestPermission()
        // Menú Servicios: "Descargar con Grabbyt" sobre un link seleccionado en cualquier app.
        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()
    }

    // La app sigue viva en la barra de menú aunque se cierre la ventana.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "showMenuBar") && UserDefaults.standard.object(forKey: "showMenuBar") != nil
    }

    /// grabbyt://download?url=<link>&mode=audio  (lo usan el bookmarklet y los atajos)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { ExternalLinks.handle(url) }
    }
}

@MainActor
enum ExternalLinks {
    static func handle(_ url: URL) {
        if url.scheme == "grabbyt" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let link = items.first(where: { $0.name == "url" })?.value else { return }
            var options = Preferences.lastOptions
            if let mode = items.first(where: { $0.name == "mode" })?.value.flatMap(MediaMode.init(rawValue:)) {
                options.mode = mode
            }
            enqueue(link, options: options)
        } else if url.scheme?.hasPrefix("http") == true {
            enqueue(url.absoluteString, options: Preferences.lastOptions)
        }
    }

    static func enqueue(_ text: String, options: DownloadOptions) {
        Task {
            // Si la app se abrió por el link, espera a que las herramientas estén listas.
            if ToolsModel.shared.phase != .ready { await ToolsModel.shared.bootstrap() }
            DownloadManager.shared.enqueue(text, options: options)
        }
    }
}

final class ServiceProvider: NSObject {
    @objc func downloadLink(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let text = pboard.string(forType: .URL) ?? pboard.string(forType: .string) ?? ""
        Task { @MainActor in ExternalLinks.enqueue(text, options: Preferences.lastOptions) }
    }
}
