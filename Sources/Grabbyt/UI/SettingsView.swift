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
            IntegrationsSettings()
                .tabItem { Label("Integraciones", systemImage: "link") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralSettings: View {
    @AppStorage("destinationPath") private var destinationPath = DownloadManager.defaultDestination.path
    @AppStorage("preferredBrowser") private var preferredBrowser = ""
    @AppStorage("maxConcurrent") private var maxConcurrent = 3
    @AppStorage("showMenuBar") private var showMenuBar = true

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

            Stepper("Descargas simultáneas: \(maxConcurrent)", value: $maxConcurrent, in: 1...6)
            Toggle("Mostrar en la barra de menú", isOn: $showMenuBar)

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

private struct IntegrationsSettings: View {
    static let bookmarklet = "javascript:location.href='grabbyt://download?url='+encodeURIComponent(location.href)"

    var body: some View {
        Form {
            Section("Desde el navegador (cualquiera)") {
                Text("Crea un marcador con esta dirección. Al pulsarlo en una página, Grabbyt la descarga.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(Self.bookmarklet).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                    Button("Copiar") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.bookmarklet, forType: .string)
                    }
                }
            }
            Section("Desde cualquier app") {
                Text("Selecciona un link → clic derecho → Servicios → “Descargar con Grabbyt”.")
                Text("También puedes arrastrar links a la ventana, o usar el icono de la barra de menú.")
            }
            Section("Atajos / Terminal") {
                Text("open 'grabbyt://download?url=<link>&mode=audio'").font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}
