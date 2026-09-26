import AppKit
import GrabbytCore
import SwiftUI
import UserNotifications

/// Opciones elegidas al pedir una descarga.
struct DownloadOptions: Codable, Equatable {
    var mode: MediaMode = .video
    var quality: VideoQuality = .best
    var audioFormat: AudioFormat = .mp3
}

@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    enum State: Equatable {
        case queued
        case running
        case done([URL])
        case failed(String)
        case cancelled
    }

    let id: UUID
    let url: String
    let options: DownloadOptions
    let createdAt: Date

    @Published var title: String?
    @Published var state: State = .queued
    @Published var status = "En cola…"
    @Published var fraction: Double?
    @Published var speed: String?
    @Published var eta: String?
    @Published var attempts: [String] = []
    @Published var log: [String] = []
    @Published var showDetails = false

    fileprivate var engine: DownloadEngine?
    fileprivate var task: Task<Void, Never>?

    init(url: String, options: DownloadOptions, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.options = options
        self.createdAt = createdAt
    }

    var mode: MediaMode { options.mode }
    var displayTitle: String { title ?? LinkParser.siteName(for: url) }
    var isRunning: Bool { state == .running }
    var isActive: Bool { state == .running || state == .queued }

    func cancel() {
        engine?.cancel()
        task?.cancel()
        if state == .queued { state = .cancelled; status = "Cancelado" }
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var jobs: [DownloadJob] = []

    @AppStorage("destinationPath") var destinationPath: String = DownloadManager.defaultDestination.path
    @AppStorage("preferredBrowser") var preferredBrowser: String = ""   // "" = automático
    @AppStorage("maxConcurrent") var maxConcurrent: Int = 3

    static let defaultDestination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Grabbyt", isDirectory: true)

    var destination: URL { URL(fileURLWithPath: destinationPath, isDirectory: true) }

    private let history = HistoryStore()

    init() {
        jobs = history.load()
    }

    var activeCount: Int { jobs.filter(\.isActive).count }

    @discardableResult
    func enqueue(_ rawText: String, options: DownloadOptions, title: String? = nil) -> Bool {
        guard let url = LinkParser.firstURL(in: rawText) else { return false }
        let job = DownloadJob(url: url, options: options)
        job.title = title
        jobs.insert(job, at: 0)
        pump()
        return true
    }

    func retry(_ job: DownloadJob, options: DownloadOptions? = nil) {
        let copy = DownloadJob(url: job.url, options: options ?? job.options)
        copy.title = job.title
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = copy
        } else {
            jobs.insert(copy, at: 0)
        }
        pump()
    }

    func remove(_ job: DownloadJob) {
        job.cancel()
        jobs.removeAll { $0.id == job.id }
        save()
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
        save()
    }

    /// Arranca trabajos en cola hasta llenar el límite de descargas simultáneas.
    private func pump() {
        let running = jobs.filter(\.isRunning).count
        let slots = max(1, maxConcurrent) - running
        guard slots > 0 else { return }
        // Los más antiguos primero.
        for job in jobs.reversed().filter({ $0.state == .queued }).prefix(slots) {
            start(job)
        }
    }

    private func start(_ job: DownloadJob) {
        let engine = DownloadEngine()
        job.engine = engine
        job.state = .running
        job.status = "Preparando…"
        let request = DownloadRequest(
            url: job.url,
            mode: job.options.mode,
            quality: job.options.quality,
            audioFormat: job.options.audioFormat,
            destination: destination,
            preferredBrowser: Browser(rawValue: preferredBrowser)
        )
        job.task = Task {
            let outcome = await engine.run(request) { event in
                Task { @MainActor in Self.apply(event, to: job) }
            }
            // Deja que se apliquen los últimos eventos antes de marcar el final.
            await Task.yield()
            switch outcome {
            case .success(let files):
                job.state = .done(files)
                job.status = files.isEmpty ? "Ya estaba descargado" : "Listo"
                job.fraction = 1
                Notifier.notify(title: "Descarga lista", body: job.displayTitle)
            case .failure(_, let message):
                job.state = .failed(message)
                job.status = "Falló"
                Notifier.notify(title: "No se pudo descargar", body: job.displayTitle)
            case .cancelled:
                job.state = .cancelled
                job.status = "Cancelado"
            }
            job.speed = nil
            job.eta = nil
            self.save()
            self.pump()
        }
    }

    private func save() {
        history.save(jobs.filter { !$0.isActive })
    }

    private static func apply(_ event: DownloadEvent, to job: DownloadJob) {
        guard job.isRunning else { return }
        switch event {
        case .attempt(let number, let config):
            job.attempts.append("yt-dlp \(number): \(config.summary)")
            job.fraction = nil
        case .status(let text):
            job.status = text
        case .title(let title):
            job.title = title
        case .progress(let fraction, let speed, let eta):
            job.fraction = fraction
            job.speed = speed
            job.eta = eta
            if job.status.hasPrefix("Analizando") || job.status.hasPrefix("Preparando") {
                job.status = fraction == nil ? "Procesando…" : "Descargando…"
            }
        case .log(let line):
            job.log.append(line)
            if job.log.count > 400 { job.log.removeFirst(job.log.count - 400) }
        case .fallback(let name):
            job.attempts.append("Fallback: \(name)")
            job.fraction = nil
        case .attemptFailed(let kind):
            if let last = job.attempts.indices.last {
                job.attempts[last] += "  ✗ \(kind.rawValue)"
            }
        }
    }
}

// MARK: - Historial en disco

/// Guarda los trabajos terminados en ~/Library/Application Support/Grabbyt/history.json.
struct HistoryStore {
    struct Record: Codable {
        var id: UUID
        var url: String
        var options: DownloadOptions
        var createdAt: Date
        var title: String?
        var state: String            // done | failed | cancelled
        var files: [String]
        var message: String?
        var attempts: [String]
    }

    private let file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Grabbyt/history.json")
    private let limit = 300

    @MainActor
    func load() -> [DownloadJob] {
        guard let data = try? Data(contentsOf: file),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return records.map { r in
            let job = DownloadJob(url: r.url, options: r.options, id: r.id, createdAt: r.createdAt)
            job.title = r.title
            job.attempts = r.attempts
            switch r.state {
            case "done":
                job.state = .done(r.files.map { URL(fileURLWithPath: $0) })
                job.status = "Listo"
                job.fraction = 1
            case "failed":
                job.state = .failed(r.message ?? "Falló")
                job.status = "Falló"
            default:
                job.state = .cancelled
                job.status = "Cancelado"
            }
            return job
        }
    }

    @MainActor
    func save(_ jobs: [DownloadJob]) {
        let records = jobs.prefix(limit).map { job -> Record in
            var state = "cancelled", files: [String] = [], message: String?
            switch job.state {
            case .done(let urls): state = "done"; files = urls.map(\.path)
            case .failed(let m): state = "failed"; message = m
            default: break
            }
            return Record(id: job.id, url: job.url, options: job.options, createdAt: job.createdAt,
                          title: job.title, state: state, files: files, message: message, attempts: job.attempts)
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(records)) {
            try? data.write(to: file, options: .atomic)
        }
    }
}

enum Notifier {
    static func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
