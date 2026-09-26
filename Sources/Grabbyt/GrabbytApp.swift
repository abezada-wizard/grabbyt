import AppKit
import SwiftUI

@main
struct GrabbytApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var downloads = DownloadManager()
    @StateObject private var tools = ToolsModel()

    var body: some Scene {
        Window("Grabbyt", id: "main") {
            ContentView()
                .environmentObject(downloads)
                .environmentObject(tools)
                .frame(minWidth: 520, minHeight: 460)
                .task { await tools.bootstrap() }
        }
        .defaultSize(width: 600, height: 640)
        .windowResizability(.contentMinSize)

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
