import AppKit
import GrabbytCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var tools: ToolsModel
    @EnvironmentObject private var updates: UpdateChecker

    // Sin @State: es una macro que solo existe con Xcode completo; así compila con Command Line Tools.
    @StateObject private var form = FormState()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let release = updates.available { updateBanner(release) }
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
            for url in urls { added = downloads.enqueue(url.absoluteString, options: form.options) || added }
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

    private func updateBanner(_ release: UpdateChecker.Release) -> some View {
        HStack {
            Image(systemName: "sparkles")
            Text("Hay una versión nueva de Grabbyt: \(release.version)")
            Spacer()
            Button("Descargar") { NSWorkspace.shared.open(release.page) }
            Button { updates.dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("🐇").font(.system(size: 26))
                Text("Grabbyt").font(.title2.bold())
                Spacer()
                Picker("", selection: $form.options.mode) {
                    Label("Video", systemImage: "film").tag(MediaMode.video)
                    Label("Audio", systemImage: "music.note").tag(MediaMode.audio)
                    Label("Imágenes", systemImage: "photo.on.rectangle").tag(MediaMode.images)
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
                    .onChange(of: form.link) {
                        form.invalidLink = false
                        form.schedulePreview()
                    }

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

            if form.previewState != .idle { previewCard }

            optionsRow
        }
        .padding(16)
    }

    @ViewBuilder
    private var optionsRow: some View {
        HStack(spacing: 12) {
            switch form.options.mode {
            case .video:
                Picker("Calidad", selection: $form.options.quality) {
                    ForEach(form.availableQualities) { q in Text(q.label).tag(q) }
                }
                .fixedSize()
            case .audio:
                Picker("Formato", selection: $form.options.audioFormat) {
                    Text("MP3").tag(AudioFormat.mp3)
                    Text("M4A").tag(AudioFormat.m4a)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            case .images:
                Text("Fotos, carruseles y galerías (Instagram, X, Pinterest, Reddit, Tumblr…)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
    }

    @ViewBuilder
    private var previewCard: some View {
        HStack(spacing: 12) {
            switch form.previewState {
            case .loading:
                ProgressView().controlSize(.small)
                Text("Buscando vista previa…").foregroundStyle(.secondary)
            case .unavailable:
                Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary)
                Text("Sin vista previa. Al descargar se probarán estrategias alternativas.")
                    .foregroundStyle(.secondary)
            case .ready(let preview):
                AsyncImage(url: preview.thumbnail) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title).font(.callout.weight(.semibold)).lineLimit(2)
                    Text([preview.uploader, preview.site, preview.durationText, preview.heights.first.map { "hasta \($0)p" },
                          preview.entryCount.map { "\($0) elementos" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case .idle:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var content: some View {
        switch tools.phase {
        case .checking, .installing:
            VStack(spacing: 12) {
                ProgressView()
                Text(installMessage).foregroundStyle(.secondary)
                Text("Solo la primera vez: yt-dlp, ffmpeg y gallery-dl (~150 MB)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
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
                VStack(spacing: 0) {
                    if downloads.jobs.count > 5 {
                        TextField("Buscar en el historial", text: $form.search)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    List {
                        ForEach(filteredJobs) { job in
                            JobRow(job: job)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    private var filteredJobs: [DownloadJob] {
        let q = form.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return downloads.jobs }
        return downloads.jobs.filter { $0.displayTitle.lowercased().contains(q) || $0.url.lowercased().contains(q) }
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

            if downloads.activeCount > 0 {
                Text("\(downloads.activeCount) activa(s)").foregroundStyle(.secondary)
            }
            if downloads.jobs.contains(where: { !$0.isActive }) {
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
        var title: String?
        if case .ready(let preview) = form.previewState { title = preview.title }
        if downloads.enqueue(form.link, options: form.options, title: title) {
            form.link = ""
            form.clearPreview()
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
    enum PreviewState: Equatable {
        case idle, loading, unavailable
        case ready(MediaPreview)
    }

    @Published var link = ""
    @Published var options: DownloadOptions = Preferences.lastOptions {
        didSet { Preferences.lastOptions = options }
    }
    @Published var invalidLink = false
    @Published var lastClipboard = ""
    @Published var isDropTargeted = false
    @Published var search = ""
    @Published var previewState: PreviewState = .idle

    private var previewTask: Task<Void, Never>?
    private var previewedURL: String?

    var availableQualities: [VideoQuality] {
        if case .ready(let preview) = previewState { return preview.qualities }
        return VideoQuality.allCases
    }

    /// Espera a que el usuario deje de escribir y pide la vista previa.
    func schedulePreview() {
        guard let url = LinkParser.firstURL(in: link) else { clearPreview(); return }
        guard url != previewedURL else { return }
        previewedURL = url
        previewTask?.cancel()
        previewState = .loading
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let preview = await MediaProbe.probe(url)
            guard !Task.isCancelled else { return }
            if let preview {
                previewState = .ready(preview)
                if !preview.qualities.contains(options.quality) { options.quality = .best }
            } else {
                previewState = .unavailable
            }
        }
    }

    func clearPreview() {
        previewTask?.cancel()
        previewedURL = nil
        previewState = .idle
    }
}

/// Preferencias que se usan también fuera de la ventana (barra de menú, grabbyt://, Servicios).
enum Preferences {
    static var lastOptions: DownloadOptions {
        get {
            guard let data = UserDefaults.standard.data(forKey: "lastOptions"),
                  let options = try? JSONDecoder().decode(DownloadOptions.self, from: data) else { return DownloadOptions() }
            return options
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: "lastOptions") }
        }
    }
}
