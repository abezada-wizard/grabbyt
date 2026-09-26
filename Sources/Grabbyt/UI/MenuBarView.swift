import AppKit
import GrabbytCore
import SwiftUI

/// Panel de la barra de menú: descarga rápida sin abrir la ventana.
struct MenuBarView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var tools: ToolsModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = MenuBarModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("🐇 Grabbyt").font(.headline)
                Spacer()
                Picker("", selection: $model.mode) {
                    Image(systemName: "film").tag(MediaMode.video)
                    Image(systemName: "music.note").tag(MediaMode.audio)
                    Image(systemName: "photo").tag(MediaMode.images)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            HStack {
                TextField("Pega un link…", text: $model.link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(download)
                Button(action: download) { Image(systemName: "arrow.down.circle.fill") }
                    .disabled(model.link.isEmpty || tools.phase != .ready)
            }

            Button {
                if let text = NSPasteboard.general.string(forType: .string) {
                    model.link = text
                    download()
                }
            } label: {
                Label("Descargar lo copiado", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.link)

            if !downloads.jobs.isEmpty {
                Divider()
                ForEach(downloads.jobs.prefix(5)) { job in
                    MenuJobRow(job: job)
                }
            }

            Divider()
            HStack {
                Button("Abrir Grabbyt") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Salir") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func download() {
        var options = Preferences.lastOptions
        options.mode = model.mode
        if downloads.enqueue(model.link, options: options) { model.link = "" }
    }
}

@MainActor
private final class MenuBarModel: ObservableObject {
    @Published var link = ""
    @Published var mode: MediaMode = Preferences.lastOptions.mode
}

private struct MenuJobRow: View {
    @ObservedObject var job: DownloadJob

    var body: some View {
        HStack(spacing: 8) {
            switch job.state {
            case .queued, .running:
                if let f = job.fraction { ProgressView(value: f).progressViewStyle(.circular).controlSize(.small) }
                else { ProgressView().controlSize(.small) }
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
            }
            Text(job.displayTitle).lineLimit(1).font(.callout)
            Spacer()
            if case .done(let files) = job.state, let file = files.first {
                Button { NSWorkspace.shared.activateFileViewerSelecting(files) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help(file.lastPathComponent)
            }
        }
    }
}
