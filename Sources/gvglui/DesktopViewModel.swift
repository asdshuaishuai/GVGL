import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GVGLCore
import GVGLQuery
import GVGLAction

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
    /// Default on: the console must not disturb the desktop it observes.
    /// Turning this off opts into synthetic pointer/keyboard input.
    @Published var backgroundMode = true

    @Published var lastInstruction: String?
    @Published var lastResult: QueryResult?
    @Published var lastParsed: ParsedInstruction?
    /// True while an action/transcript call is in flight (they block for up to
    /// the verification window).
    @Published var busy = false
    /// Newest-first log of actions executed from the console. This is the
    /// observation surface: method, whether the desktop changed, and whether
    /// the change was verified.
    @Published var actionLog: [ActionLogEntry] = []
    /// Text of a window read through AX — the screenshot-free "what does it
    /// say" panel.
    @Published var transcript: String?
    @Published var transcriptLabel: String?
    @Published var axTrusted = AXIsProcessTrusted()

    /// One executed action, as the console saw it.
    struct ActionLogEntry: Identifiable {
        let id = UUID()
        let time: Date
        let action: String
        let target: String?
        let method: String?
        /// "background" or "foreground" — which policy the action ran under.
        let isolation: String?
        let changed: Bool
        let verified: Bool
        let latencyMS: Int
        let errorCode: String?
        let errorMessage: String?

        var ok: Bool { errorCode == nil }

        var detail: String {
            if let errorCode {
                return "\(errorCode): \(errorMessage ?? "")"
            }
            var parts: [String] = []
            if let isolation {
                parts.append(isolation == InteractionMode.background.rawValue ? "后台" : "前台")
            }
            if let method { parts.append(method) }
            parts.append(changed ? "已变化" : "无变化")
            parts.append(verified ? "已验证" : "未验证")
            parts.append("\(latencyMS)ms")
            return parts.joined(separator: " · ")
        }
    }

    /// The console never re-implements clicking: it drives the same executor
    /// agents use, so what a human sees here is exactly what an agent gets.
    private var executor: ActionExecutor

    /// One incremental frame change (from get_frame?since), newest first.
    /// Makes the event-driven engine observable: which apps changed, when.
    struct FrameEvent: Identifiable {
        let id = UUID()
        let time: Date
        let version: UInt64
        let changedApps: [String]
        /// The daemon could not describe every skipped mutation (change log
        /// rolled over, or the cursor came from a previous daemon). The frame
        /// is complete, but `changedApps` is NOT an exhaustive list — the UI
        /// must not present it as one.
        let requiresFullRefresh: Bool
    }
    @Published var events: [FrameEvent] = []
    private let eventCapacity = 50

    private var client: GVGLClient?
    private var subscription: GVGLClient.Subscription?
    private var watchTask: Task<Void, Never>?
    private var lastVersion: UInt64?

    init() {
        // Read the default once, before touching `self`: @Published's setter
        // counts as a property access, and `executor` is not initialized yet.
        let path = GVGLClient.defaultSocketPath
        socketPath = path
        client = GVGLClient(socketPath: path)
        executor = ActionExecutor(options: ExecutorOptions(socketPath: path), mode: .background)
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
        executor = ActionExecutor(options: ExecutorOptions(socketPath: socketPath),
                                  mode: backgroundMode ? .background : .foreground)
        axTrusted = AXIsProcessTrusted()
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
            // Give it a moment, then refresh. `refresh()` is synchronous
            // @MainActor (it schedules its own Task), so there is nothing to
            // await here — the previous `await refresh()` was a no-op that
            // only compiled with a warning.
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                self.refresh()
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
                // Keep the cursor in step with the frame we just took. Leaving
                // it stale (it was previously only set by watchStep) made the
                // next poll use a cursor from an older daemon incarnation —
                // which the server now answers with a full refresh, so it
                // self-heals, but only after a wasted round trip.
                self.lastVersion = frame.version
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
                               changedApps: result.changedApps,
                               requiresFullRefresh: result.requiresFullRefresh),
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

    // MARK: - Actions (computer use)

    func performPress(_ entity: Entity) {
        runAction("press", target: entity) { [executor] in
            try executor.press(.id(entity.id))
        }
    }

    func performClick(_ entity: Entity) {
        runAction("click", target: entity) { [executor] in
            try executor.click(.id(entity.id))
        }
    }

    func performType(_ text: String, into entity: Entity?) {
        guard let entity else {
            errorMessage = "先选中一个输入控件"
            return
        }
        guard !text.isEmpty else {
            errorMessage = "输入文本为空"
            return
        }
        runAction("type", target: entity) { [executor] in
            try executor.type(.id(entity.id), text: text)
        }
    }

    func performKey(_ chord: String) {
        guard !chord.isEmpty else {
            errorMessage = "按键和弦为空"
            return
        }
        runAction("key", target: nil) { [executor] in
            try executor.sendKey(chord)
        }
    }

    func performScroll(_ entity: Entity?, lines: Int32) {
        guard let entity else {
            errorMessage = "先选中一个可滚动区域"
            return
        }
        runAction("scroll", target: entity) { [executor] in
            try executor.scroll(.id(entity.id), lines: lines)
        }
    }

    /// Console self-test: run one harmless action against this console through
    /// the same executor agents use. Target is the sidebar's filter field —
    /// under the daemon's default node budget the sidebar's 500-row entity
    /// list exhausts the capture before the top strip, so the socket-path
    /// field is NOT in the frame (verified live: the filter field was the
    /// only AXTextField captured). Focusing the filter field is idempotent,
    /// reliably visible to the daemon, and the focus event bumps the version
    /// — a real, verified action-log entry without touching the desktop.
    func runSelfTest() {
        let ownAppKey = "pid:\(ProcessInfo.processInfo.processIdentifier)"
        runAction("focus", target: nil) { [executor] in
            try executor.focus(.query(QueryParams(role: "AXTextField", label: "过滤", app: ownAppKey, top: 5)))
        }
    }

    /// Replace the executor rather than mutating it: an in-flight action keeps
    /// the policy it started under, and the next action uses the new one.
    func setIsolation(background: Bool) {
        executor = ActionExecutor(
            options: ExecutorOptions(socketPath: executor.options.socketPath),
            mode: background ? .background : .foreground
        )
    }

    // MARK: - Transcript (read-only; never gated by the execute toggle)

    func loadTranscriptForSelection() {
        guard let entity = selectedEntity else {
            errorMessage = "先在画布或左侧列表选中一个实体"
            return
        }
        let windowID = entity.role == "AXWindow" ? entity.id : entity.windowID
        loadTranscript(appKey: entity.appID, windowID: windowID,
                       label: entityDisplayTitle(entity))
    }

    func loadTranscriptFrontmost() {
        guard let frame else { return }
        guard let appKey = frame.frontmostApp else {
            errorMessage = "帧里没有前台 App 信息"
            return
        }
        let name = frame.scene.first { $0.appKey == appKey }?.name ?? appKey
        loadTranscript(appKey: appKey, windowID: nil, label: name)
    }

    private func loadTranscript(appKey: String, windowID: String?, label: String) {
        busy = true
        let executor = self.executor
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try executor.transcript(appKey: appKey, windowID: windowID) }
            }.value
            self.busy = false
            switch outcome {
            case .success(let result):
                if case .object(let object) = result.data,
                   case .string(let text)? = object["text"] {
                    self.transcript = text
                    self.transcriptLabel = label
                } else {
                    self.transcript = nil
                    self.errorMessage = "该窗口没有可读文本（AX 未暴露）"
                }
            case .failure(let error):
                self.errorMessage = (error as? ActionFailure)?.error.message ?? "\(error)"
            }
        }
    }

    // MARK: - Action plumbing

    private func runAction(_ label: String, target: Entity?,
                           _ body: @escaping () throws -> ActionResult) {
        guard allowExecute else {
            errorMessage = "请在侧栏开启「允许执行动作」"
            return
        }
        busy = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try body() }
            }.value
            self.busy = false
            self.record(outcome, label: label, target: target)
        }
    }

    private func record(_ outcome: Result<ActionResult, Error>, label: String, target: Entity?) {
        let entry: ActionLogEntry
        switch outcome {
        case .success(let result):
            entry = ActionLogEntry(
                time: Date(), action: label,
                target: target.map(entityDisplayTitle) ?? result.target?.title,
                method: result.method,
                isolation: (result.isolation ?? executor.mode).rawValue,
                changed: result.changed,
                verified: result.verified, latencyMS: result.latencyMS,
                errorCode: result.error?.code.rawValue,
                errorMessage: result.error?.message
            )
            if let error = result.error {
                errorMessage = "\(error.code.rawValue): \(error.message)"
            }
        case .failure(let error):
            let failure = error as? ActionFailure
            entry = ActionLogEntry(
                time: Date(), action: label,
                target: target.map(entityDisplayTitle),
                method: nil, isolation: executor.mode.rawValue,
                changed: false, verified: false, latencyMS: 0,
                errorCode: failure?.error.code.rawValue ?? "internal_error",
                errorMessage: failure?.error.message ?? "\(error)"
            )
            errorMessage = entry.detail
        }
        actionLog.insert(entry, at: 0)
        if actionLog.count > 50 {
            actionLog.removeLast(actionLog.count - 50)
        }
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
