import GrabbytCore
import SwiftUI

/// Estado de las herramientas para la UI (el trabajo real lo hace el actor ToolManager).
@MainActor
final class ToolsModel: ObservableObject {
    static let shared = ToolsModel()
    private var bootstrapTask: Task<Void, Never>?
    enum Phase: Equatable {
        case checking
        case installing(String)
        case ready
        case failed(String)
    }

    @Published var phase: Phase = .checking
    @Published var infos: [Tool: ToolInfo] = [:]
    @Published var isUpdating = false
    @Published var lastMessage: String?

    private let manager = ToolManager.shared

    var binDirectory: URL { manager.binDir }

    /// Si ya se está preparando (p. ej. la app se abrió desde un link), espera a esa misma preparación.
    func bootstrap() async {
        if let running = bootstrapTask { return await running.value }
        let task = Task { await performBootstrap() }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }

    private func performBootstrap() async {
        phase = .checking
        let missing = await manager.missingTools()
        let hasManagedYtDlp = await manager.managedPath(for: .ytdlp)?.path.contains("yt-dlp-dist") == true

        if !missing.isEmpty || !hasManagedYtDlp {
            phase = .installing("Preparando herramientas…")
            do {
                try await manager.installMissing { message in
                    Task { @MainActor in self.phase = .installing(message) }
                }
            } catch {
                // Solo es fatal si yt-dlp no existe en ningún lado.
                if await manager.path(for: .ytdlp) == nil {
                    phase = .failed(error.localizedDescription)
                    return
                }
                lastMessage = error.localizedDescription
            }
        }
        await refresh()
        phase = .ready

        // Mantener yt-dlp al día en segundo plano: los sitios cambian seguido.
        Task { await manager.updateYtDlpIfStale(); await refresh() }
    }

    func refresh() async {
        var result: [Tool: ToolInfo] = [:]
        for tool in Tool.allCases {
            result[tool] = await manager.info(for: tool)
        }
        infos = result
    }

    func updateYtDlp() async {
        isUpdating = true
        let ok = await manager.updateYtDlp(force: true)
        lastMessage = ok ? "yt-dlp actualizado" : "No se pudo actualizar yt-dlp"
        await refresh()
        isUpdating = false
    }

    func reinstall(_ tool: Tool) async {
        isUpdating = true
        do {
            try await manager.install(tool)
            lastMessage = "\(tool.rawValue) reinstalado"
        } catch {
            lastMessage = error.localizedDescription
        }
        await refresh()
        isUpdating = false
    }

    var hasFfmpeg: Bool { infos[.ffmpeg]?.path != nil }
}
