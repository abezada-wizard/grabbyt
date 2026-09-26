import AppKit
import GrabbytCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ToolsSettings()
                .tabItem { Label("Herramientas", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 500, height: 320)
    }
}

private struct GeneralSettings: View {
    @AppStorage("destinationPath") private var destinationPath = DownloadManager.defaultDestination.path
    @AppStorage("preferredBrowser") private var preferredBrowser = ""

    var body: some View {
        Form {
            LabeledContent("Guardar en") {
                HStack {
                    Text(destinationPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Cambiar…", action: chooseFolder)
                }
            }

            Picker("Cookies del navegador", selection: $preferredBrowser) {
                Text("Automático").tag("")
                ForEach(Browser.installed()) { browser in
                    Text(browser.displayName).tag(browser.rawValue)
                }
            }
            Text("Solo se usan si un sitio pide iniciar sesión (Instagram, tweets protegidos, videos +18). Elige el navegador donde tienes la sesión abierta. Safari requiere dar a Grabbyt “Acceso total al disco”.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: destinationPath)
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
        }
    }
}

private struct ToolsSettings: View {
    @EnvironmentObject private var tools: ToolsModel

    var body: some View {
        Form {
            ForEach(Tool.allCases, id: \.self) { tool in
                let info = tools.infos[tool]
                LabeledContent(tool.rawValue) {
                    HStack {
                        if let info, info.path != nil {
                            Text(info.version ?? "?").monospaced()
                            Text(info.managed ? "Grabbyt" : "sistema")
                                .font(.caption)
                                .padding(.horizontal, 5)
                                .background(.quaternary, in: Capsule())
                        } else {
                            Text("No instalado").foregroundStyle(.red)
                        }
                        Button("Reinstalar") { Task { await tools.reinstall(tool) } }
                            .disabled(tools.isUpdating)
                    }
                }
            }

            HStack {
                Button("Actualizar yt-dlp ahora") { Task { await tools.updateYtDlp() } }
                    .disabled(tools.isUpdating)
                if tools.isUpdating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abrir carpeta") { NSWorkspace.shared.open(tools.binDirectory) }
            }

            if let message = tools.lastMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("yt-dlp se actualiza solo una vez al día y también cuando una descarga falla por un extractor roto.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { await tools.refresh() }
    }
}
