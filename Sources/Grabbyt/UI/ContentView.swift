import AppKit
import GrabbytCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var tools: ToolsModel

    // Sin @State: es una macro que solo existe con Xcode completo; así compila con Command Line Tools.
    @StateObject private var form = FormState()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(form.isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            var added = false
            for url in urls { added = downloads.enqueue(url.absoluteString, mode: form.mode) || added }
            return added
        } isTargeted: { form.isDropTargeted = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pickUpClipboard()
        }
        .onAppear {
            fieldFocused = true
            pickUpClipboard()
        }
    }

    // MARK: - Secciones

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("🐇").font(.system(size: 26))
                Text("Grabbyt").font(.title2.bold())
                Spacer()
                Picker("", selection: $form.mode) {
                    Label("Video", systemImage: "film").tag(MediaMode.video)
                    Label("Audio", systemImage: "music.note").tag(MediaMode.audio)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            HStack(spacing: 8) {
                TextField("Pega un link de X, YouTube, TikTok, Instagram…", text: $form.link)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .onChange(of: form.link) { form.invalidLink = false }

                Button {
                    if let text = NSPasteboard.general.string(forType: .string) { form.link = text }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .controlSize(.large)
                .help("Pegar del portapapeles")

                Button(action: submit) {
                    Label("Descargar", systemImage: "arrow.down.circle.fill")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(form.link.trimmingCharacters(in: .whitespaces).isEmpty || tools.phase != .ready)
            }

            if form.invalidLink {
                Text("Eso no parece un link válido.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch tools.phase {
        case .checking, .installing:
            VStack(spacing: 12) {
                ProgressView()
                Text(installMessage).foregroundStyle(.secondary)
                Text("Solo la primera vez: yt-dlp y ffmpeg (~100 MB)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("No se pudieron instalar las herramientas", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Reintentar") { Task { await tools.bootstrap() } }
            }
        case .ready:
            if downloads.jobs.isEmpty {
                ContentUnavailableView {
                    Label("Nada descargado aún", systemImage: "arrow.down.to.line")
                } description: {
                    Text("Pega un link arriba o arrástralo a esta ventana.")
                }
            } else {
                List {
                    ForEach(downloads.jobs) { job in
                        JobRow(job: job)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.open(downloads.destination)
            } label: {
                Label(downloads.destination.lastPathComponent, systemImage: "folder")
            }
            .buttonStyle(.link)
            .help(downloads.destination.path)

            if tools.phase == .ready && !tools.hasFfmpeg {
                Label("Sin ffmpeg: calidad limitada", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if downloads.jobs.contains(where: { !$0.isRunning }) {
                Button("Limpiar terminados") { downloads.clearFinished() }
                    .buttonStyle(.link)
            }
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Acciones

    private var installMessage: String {
        if case .installing(let message) = tools.phase { return message }
        return "Revisando herramientas…"
    }

    private func submit() {
        guard tools.phase == .ready else { return }
        if downloads.enqueue(form.link, mode: form.mode) {
            form.link = ""
        } else {
            form.invalidLink = true
        }
    }

    /// Si al volver a la app hay un link nuevo en el portapapeles, lo pone en el campo.
    private func pickUpClipboard() {
        guard form.link.isEmpty,
              let text = NSPasteboard.general.string(forType: .string),
              text != form.lastClipboard,
              let url = LinkParser.firstURL(in: text),
              !downloads.jobs.contains(where: { $0.url == url })
        else { return }
        form.lastClipboard = text
        form.link = url
    }
}

@MainActor
private final class FormState: ObservableObject {
    @Published var link = ""
    @Published var mode: MediaMode = .video
    @Published var invalidLink = false
    @Published var lastClipboard = ""
    @Published var isDropTargeted = false
}
