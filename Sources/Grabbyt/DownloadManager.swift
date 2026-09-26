import AppKit
import GrabbytCore
import SwiftUI
import UserNotifications

@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case done([URL])
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let url: String
    let mode: MediaMode
    let createdAt = Date()

    @Published var title: String?
    @Published var state: State = .running
    @Published var status = "Preparando…"
    @Published var fraction: Double?
    @Published var speed: String?
    @Published var eta: String?
    @Published var attempts: [String] = []
    @Published var log: [String] = []
    @Published var showDetails = false

    fileprivate var engine: DownloadEngine?
    fileprivate var task: Task<Void, Never>?

    init(url: String, mode: MediaMode) {
        self.url = url
        self.mode = mode
    }

    var displayTitle: String { title ?? LinkParser.siteName(for: url) }
    var isRunning: Bool { state == .running }

    func cancel() {
        engine?.cancel()
        task?.cancel()
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published var jobs: [DownloadJob] = []

    @AppStorage("destinationPath") var destinationPath: String = DownloadManager.defaultDestination.path
    @AppStorage("preferredBrowser") var preferredBrowser: String = ""   // "" = automático

    static let defaultDestination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Grabbyt", isDirectory: true)

    var destination: URL { URL(fileURLWithPath: destinationPath, isDirectory: true) }

    func enqueue(_ rawText: String, mode: MediaMode) -> Bool {
        guard let url = LinkParser.firstURL(in: rawText) else { return false }
        let job = DownloadJob(url: url, mode: mode)
        jobs.insert(job, at: 0)
        start(job)
        return true
    }

    func retry(_ job: DownloadJob) {
        let copy = DownloadJob(url: job.url, mode: job.mode)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = copy
        } else {
            jobs.insert(copy, at: 0)
        }
        start(copy)
    }

    func remove(_ job: DownloadJob) {
        job.cancel()
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isRunning }
    }

    private func start(_ job: DownloadJob) {
        let engine = DownloadEngine()
        job.engine = engine
        let request = DownloadRequest(
            url: job.url,
            mode: job.mode,
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
        }
    }

    private static func apply(_ event: DownloadEvent, to job: DownloadJob) {
        guard job.isRunning else { return }
        switch event {
        case .attempt(let number, let config):
            job.attempts.append("Intento \(number): \(config.summary)")
            job.fraction = nil
        case .status(let text):
            job.status = text
        case .title(let title):
            job.title = title
        case .progress(let fraction, let speed, let eta):
            job.fraction = fraction
            job.speed = speed
            job.eta = eta
            job.status = fraction == nil ? "Procesando…" : "Descargando…"
        case .log(let line):
            job.log.append(line)
            if job.log.count > 400 { job.log.removeFirst(job.log.count - 400) }
        case .fallback(let name):
            job.attempts.append("Intento \(job.attempts.count + 1): \(name)")
            job.fraction = nil
        case .attemptFailed(let kind):
            if let last = job.attempts.indices.last {
                job.attempts[last] += "  ✗ \(kind.rawValue)"
            }
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
