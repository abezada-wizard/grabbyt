import AppKit
import GrabbytCore
import SwiftUI

struct JobRow: View {
    @ObservedObject var job: DownloadJob
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                icon
                    .font(.title2)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(job.displayTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                actions
            }

            if job.isRunning {
                if let fraction = job.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }

            HStack(spacing: 6) {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(job.showDetails ? nil : 2)
                    .textSelection(.enabled)
                Spacer()
                Button(job.showDetails ? "Ocultar detalles" : "Detalles") { job.showDetails.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            if job.showDetails { details }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Copiar link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.url, forType: .string)
            }
            Button("Abrir en el navegador") {
                if let url = URL(string: job.url) { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Quitar de la lista", role: .destructive) { downloads.remove(job) }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch job.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch job.state {
        case .queued, .running:
            Button { job.cancel() } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .help("Cancelar")
        case .done(let files):
            if let file = files.first {
                Button { NSWorkspace.shared.open(file) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
                    .help("Abrir")
                Button { NSWorkspace.shared.activateFileViewerSelecting(files) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless)
                    .help("Mostrar en Finder")
            }
        case .failed, .cancelled:
            Button { downloads.retry(job) } label: { Image(systemName: "arrow.clockwise.circle") }
                .buttonStyle(.borderless)
                .help("Reintentar")
        }
    }

    private var statusLine: String {
        switch job.state {
        case .queued:
            return "En cola…"
        case .running:
            var parts = [job.status]
            if let f = job.fraction { parts.append(String(format: "%.0f%%", f * 100)) }
            if let s = job.speed { parts.append(s) }
            if let e = job.eta { parts.append("quedan \(e)") }
            return parts.joined(separator: " · ")
        case .done(let files):
            let names = files.map(\.lastPathComponent).joined(separator: ", ")
            let via = job.attempts.count > 1 ? " (tras \(job.attempts.count) intentos)" : ""
            if files.count > 3 { return "\(files.count) archivos" + via }
            return (names.isEmpty ? job.status : names) + via
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelado"
        }
    }

    private var subtitle: String {
        var parts = [LinkParser.siteName(for: job.url)]
        switch job.options.mode {
        case .audio: parts.append(job.options.audioFormat.rawValue.uppercased())
        case .images: parts.append("imágenes")
        case .video: if job.options.quality != .best { parts.append(job.options.quality.label) }
        }
        parts.append(job.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        if case .failed = job.state { return .red }
        return .secondary
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(job.attempts.enumerated()), id: \.offset) { _, attempt in
                Text(attempt).font(.caption.monospaced())
            }
            ScrollView {
                Text(job.log.suffix(120).joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 140)
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Button("Copiar registro") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString((job.attempts + [""] + job.log).joined(separator: "\n"), forType: .string)
            }
            .font(.caption)
        }
    }
}
