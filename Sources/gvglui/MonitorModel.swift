import AppKit
import Combine
import Foundation
import GVGLQuery

/// Menu-bar monitor state: cheap get_status polling (no frames, ~1ms/request).
@MainActor
final class MonitorModel: ObservableObject {
    @Published var connected = false
    @Published var status: GVGLClient.DaemonStatus?
    @Published var errorMessage: String?
    @Published var autoWatch = true

    let socketPath: String
    private let client: GVGLClient
    private var pollTask: Task<Void, Never>?

    init(socketPath: String = GVGLClient.defaultSocketPath) {
        self.socketPath = socketPath
        self.client = GVGLClient(socketPath: socketPath, timeout: 5)
        startPolling()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refresh() async {
        guard autoWatch else { return }
        do {
            let status = try await Task.detached(priority: .utility) { [client] in
                try client.getStatusTyped()
            }.value
            self.status = status
            self.connected = true
            self.errorMessage = nil
        } catch {
            self.connected = false
            self.errorMessage = error.localizedDescription
        }
    }

    func refreshNow() {
        Task { await refresh() }
    }

    /// Start (or restart) the daemon: embedded helper in this app's
    /// Resources, falling back to a sibling binary.
    func launchDaemon() {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("gvgl"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("gvgl"),
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            launchProcess(candidate, arguments: ["--reconcile", "3"])
            return
        }
        errorMessage = "未找到 gvgl 守护进程"
    }

    private func launchProcess(_ bin: URL, arguments: [String]) {
        let process = Process()
        process.executableURL = bin
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            errorMessage = "启动 \(bin.lastPathComponent) 失败: \(error.localizedDescription)"
        }
    }

    func quit() {
        pollTask?.cancel()
        exit(0)
    }
}
