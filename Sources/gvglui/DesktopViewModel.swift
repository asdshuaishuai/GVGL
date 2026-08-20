import AppKit
import CoreGraphics
import Foundation
import GVGLCore
import GVGLQuery

/// Central observable state of the review console.
@MainActor
final class DesktopViewModel: ObservableObject {
    @Published var socketPath: String = GVGLClient.defaultSocketPath
    @Published var frame: GVGLFrame?
    @Published var status: [String: Any]?
    @Published var connected = false
    @Published var errorMessage: String?
    @Published var selectedID: String?
    @Published var autoWatch = true
    @Published var allowExecute = false

    @Published var lastInstruction: String?
    @Published var lastResult: QueryResult?
    @Published var lastParsed: ParsedInstruction?
    @Published var executing = false

    /// One incremental frame change (from get_frame?since), newest first.
    /// Makes the event-driven engine observable: which apps changed, when.
    struct FrameEvent: Identifiable {
        let id = UUID()
        let time: Date
        let version: UInt64
        let changedApps: [String]
    }
    @Published var events: [FrameEvent] = []
    private let eventCapacity = 50

    private var client: GVGLClient?
    private var subscription: GVGLClient.Subscription?
    private var watchTask: Task<Void, Never>?
    private var lastVersion: UInt64?

    init() {
        client = GVGLClient(socketPath: socketPath)
    }

    /// Embedded daemon helper: "GVGL Console.app/Contents/Resources/gvgl"
    /// when running as a bundle, otherwise the sibling binary.
    var embeddedDaemonPath: URL? {
        if let bundleURL = Bundle.main.resourceURL {
            let embedded = bundleURL.appendingPathComponent("gvgl")
            if FileManager.default.isExecutableFile(atPath: embedded.path) {
                return embedded
            }
        }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("gvgl")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    private var daemonLaunchAttempted = false

    func reconnect() {
        watchTask?.cancel()
        subscription?.cancel()
        daemonLaunchAttempted = false
        client = GVGLClient(socketPath: socketPath)
        connected = false
        errorMessage = nil
        refresh()
        startWatching()
    }

    /// Starts the embedded daemon (once per reconnect) and retries.
    func startDaemon() {
        guard !daemonLaunchAttempted else { return }
        daemonLaunchAttempted = true
        guard let daemon = embeddedDaemonPath else {
            errorMessage = "未找到内嵌守护进程（预期在应用 Resources/gvgl）"
            return
        }
        do {
            try FileManager.default.createDirectory(
                atPath: NSHomeDirectory() + "/.gvgl/logs", withIntermediateDirectories: true)
        } catch {}
        let process = Process()
        process.executableURL = daemon
        process.arguments = ["--reconcile", "3"]
        let log = FileHandle(forWritingAtPath: NSHomeDirectory() + "/.gvgl/logs/gvgl.out.log")
            ?? FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
            fputs("gvglui: embedded daemon started\n", stderr)
            // Give it a moment, then refresh.
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                await refresh()
            }
        } catch {
            errorMessage = "启动守护进程失败: \(error.localizedDescription)"
        }
    }

    func refresh() {
        guard let client else { return }
        Task {
            do {
                let frame = try await Task.detached(priority: .userInitiated) {
                    try client.getFrame()
                }.value
                self.frame = frame
                self.connected = true
                self.errorMessage = nil
                fputs("gvglui: frame v\(frame.version) entities=\(frame.allEntities.count)\n", stderr)
            } catch {
                self.connected = false
                self.errorMessage = error.localizedDescription
                fputs("gvglui: refresh failed: \(error)\n", stderr)
                // Auto-start the embedded daemon on first connection failure.
                self.startDaemon()
            }
        }
    }

    func startWatching() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.watchStep()
            }
        }
    }

    private func watchStep() async {
        guard autoWatch, let client else { return }
        let since = lastVersion ?? frame?.version
        guard let since else {
            refresh()
            return
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try client.getFrameSince(since)
            }.value
            if let newFrame = result.frame {
                frame = newFrame
                lastVersion = newFrame.version
                connected = true
                events.insert(
                    FrameEvent(time: Date(), version: newFrame.version,
                               changedApps: result.changedApps),
                    at: 0
                )
                if events.count > eventCapacity {
                    events.removeLast(events.count - eventCapacity)
                }
            } else if frame == nil {
                refresh()
            }
        } catch {
            // Ignore transient subscribe/pull errors; keep last frame.
            if frame == nil {
                errorMessage = error.localizedDescription
                connected = false
            }
        }
    }

    // MARK: - Instructions

    func runInstruction(_ text: String) throws {
        lastInstruction = text
        let parsed = try InstructionParser.parse(text)
        lastParsed = parsed
        guard let frame else {
            throw NSError(domain: "gvglui", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "尚无帧数据，请先连接守护进程"])
        }

        var params = parsed.params
        if let ref = parsed.reference {
            // Two-stage relation: resolve the reference entity first.
            let refParams = QueryParams(role: ref.role, label: ref.label, top: 5)
            let refResult = QueryEngine.query(frame: frame, params: refParams)
            guard let refBest = refResult.best else {
                throw NSError(domain: "gvglui", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "找不到参照物「\(ref.label ?? "")」"])
            }
            params.refID = refBest.id
        }

        lastResult = QueryEngine.query(frame: frame, params: params)
    }

    func executeBest() {
        guard let result = lastResult, let best = result.best else { return }
        executeClick(best.entity)
    }

    func executeClick(_ entity: Entity) {
        guard allowExecute, let frame else { return }
        executing = true
        defer { executing = false }
        let point = QueryEngine.pixelCenter(of: entity, screen: frame.screen)
        let position = CGPoint(x: point.x, y: point.y)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: position, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: position, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func select(_ entityID: String?) {
        selectedID = entityID
    }

    /// The selected entity in the current frame (nil when it vanished from
    /// the latest capture — the inspector hides itself then).
    var selectedEntity: Entity? {
        guard let selectedID, let frame else { return nil }
        return frame.allEntities.first { $0.id == selectedID }
    }
}
