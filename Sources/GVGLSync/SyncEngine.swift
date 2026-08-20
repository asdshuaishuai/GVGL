import AppKit
import Foundation
import GVGLCore

public struct AppInfo: Sendable {
    public var appKey: String
    public var pid: Int32
    public var bundleID: String?
    public var name: String?

    public init(appKey: String, pid: Int32, bundleID: String?, name: String?) {
        self.appKey = appKey
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }
}

/// Display hotplug / resolution changes (M3). Module-level constant so
/// register/remove share one stable C function pointer. Delivered on the
/// main runloop, which the daemon runs (RunLoop.main.run()).
private let displayReconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, refcon in
    // Skip the "begin" phase; act once the change has settled.
    guard !flags.contains(.beginConfigurationFlag), let refcon else { return }
    let engine = Unmanaged<SyncEngine>.fromOpaque(refcon).takeUnretainedValue()
    engine.displaysDidReconfigure()
}

public protocol AppCapturing: Sendable {
    func snapshot(pid: Int32, appKey: String) -> AXAppSnapshot
    /// Subtree capture rooted at the window identified by `path` (indices under
    /// the app root). Returning nil makes the engine fall back to a full
    /// capture.
    func snapshotWindow(pid: Int32, appKey: String, path: [Int]) -> AXAppSnapshot?
}

extension AppCapturing {
    public func snapshotWindow(pid: Int32, appKey: String, path: [Int]) -> AXAppSnapshot? { nil }
}

extension Snapshotter: AppCapturing {}

/// The semi-sync engine: event-driven (AXObserver via DirtyTracker debounce)
/// with periodic full re-capture (Reconciler) as the eventual-consistency backstop.
public final class SyncEngine: @unchecked Sendable {
    public let model: DesktopModel
    public private(set) var screen: ScreenInfo
    public var debounceInterval: TimeInterval
    public var reconciliationInterval: TimeInterval
    /// Min gap between two captures of the same app (dirty-storm throttle).
    public var minCaptureInterval: TimeInterval = 0.15
    /// After an error/slow capture, back off this long before capturing again.
    public var cooldownOnError: TimeInterval = 30
    /// Max apps re-captured per reconciler tick (spike smoothing floor).
    public var reconcileBatch: Int = 3
    /// Target wall-clock for one full reconciliation sweep over all monitored
    /// apps. The per-tick batch adapts so the sweep completes within this
    /// budget no matter how many apps are online (80 apps @3s tick → 16/tick
    /// → sweep in ~15s instead of ~80s at a fixed batch of 3).
    public var reconcileSweepTarget: TimeInterval = 15
    /// If set, only apps whose bundle id is in this set are monitored.
    public var allowedBundleIDs: Set<String>?
    /// If set, called each reconciler tick to refresh the screen geometry
    /// (display resolution/scale changes should not stale normalization).
    public var screenReader: (() -> ScreenInfo)?
    /// Index grid resolution used by the pipeline (0 = linear scan).
    public var indexGridSize: Int = 0
    /// V4: frames are scene trees and no longer carry precomputed relations
    /// (clients compute them geometrically on demand) — so the daemon skips
    /// the O(N²) relation pass entirely.
    public var computeRelations = false

    private let lock = NSLock()
    private var infos: [String: AppInfo] = [:]
    private var lastCaptured: [String: Date] = [:]
    private var cooldownUntil: [String: Date] = [:]
    private var dirty = Set<String>()
    /// Window-level change hints (appKey → window rects) for subtree recapture.
    private var pendingWindowRects: [String: [NormRect]] = [:]
    private var pendingDebounce: DispatchWorkItem?

    private let capturer: AppCapturing
    private let syncQueue = DispatchQueue(label: "gvgl.sync", qos: .userInitiated)
    private let debounceQueue = DispatchQueue(label: "gvgl.debounce")
    private var observerRegistry: ObserverRegistry?
    private var workspaceTracker: WorkspaceTracker?
    private var reconcilerTimer: DispatchSourceTimer?
    private var started = false

    public init(
        model: DesktopModel,
        capturer: AppCapturing,
        screen: ScreenInfo,
        debounceInterval: TimeInterval = 0.05,
        reconciliationInterval: TimeInterval = 3.0
    ) {
        self.model = model
        self.capturer = capturer
        self.screen = screen
        self.debounceInterval = debounceInterval
        self.reconciliationInterval = reconciliationInterval
    }

    // MARK: - Lifecycle

    public func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        observerRegistry = ObserverRegistry { [weak self] pid, rect in
            guard let self else { return }
            if let rect {
                self.markWindowDirty(pid: pid, rect: rect)
            } else {
                self.markDirty(pid: pid)
            }
        }

        let tracker = WorkspaceTracker(
            onLaunched: { [weak self] app in self?.monitorApp(app: app) },
            onTerminated: { [weak self] app in self?.unmonitor(pid: app.processIdentifier) },
            onActivated: { [weak self] app in
                self?.model.setFrontmost(appKey: "pid:\(app.processIdentifier)")
            }
        )
        tracker.start()
        workspaceTracker = tracker

        // Seed the frontmost app (no activation notification fires for the
        // app that was already active when the daemon started).
        if let front = NSWorkspace.shared.frontmostApplication {
            model.setFrontmost(appKey: "pid:\(front.processIdentifier)")
        }

        let ownPID = Int32(getpid())
        for app in WorkspaceTracker.runningWindowedApps(excluding: [ownPID]) {
            monitorApp(app: app)
        }

        // Display hotplug / resolution changes: re-read the screen geometry
        // immediately (normalization base changed → every cached coordinate
        // is stale) and schedule a full refresh, instead of waiting for the
        // next reconcile tick.
        CGDisplayRegisterReconfigurationCallback(
            displayReconfigCallback, Unmanaged.passUnretained(self).toOpaque()
        )

        startReconciler()
    }

    public func stop() {
        CGDisplayRemoveReconfigurationCallback(
            displayReconfigCallback, Unmanaged.passUnretained(self).toOpaque()
        )
        reconcilerTimer?.cancel()
        reconcilerTimer = nil
        workspaceTracker?.stop()
        workspaceTracker = nil
        lock.lock()
        let pids = Array(infos.values.map(\.pid))
        infos.removeAll()
        lock.unlock()
        for pid in pids {
            observerRegistry?.stopMonitoring(pid: pid)
        }
    }

    // MARK: - App monitoring

    public func monitorApp(app: NSRunningApplication) {
        monitor(info: AppInfo(
            appKey: "pid:\(app.processIdentifier)",
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            name: app.localizedName
        ))
    }

    public func monitor(info: AppInfo) {
        // Whitelist mode is strict: apps without a bundle id can't match any
        // entry, so they must NOT slip through (previously they did).
        if let allowed = allowedBundleIDs {
            guard let bundle = info.bundleID, allowed.contains(bundle) else { return }
        }
        lock.lock()
        guard infos[info.appKey] == nil else {
            lock.unlock()
            return
        }
        infos[info.appKey] = info
        lock.unlock()

        observerRegistry?.startMonitoring(pid: info.pid)
        model.setStatus(appKey: info.appKey, pid: info.pid, .warming)
        markDirty(pid: info.pid)
    }

    public func unmonitor(pid: Int32) {
        let key = "pid:\(pid)"
        lock.lock()
        infos.removeValue(forKey: key)
        lastCaptured.removeValue(forKey: key)
        lock.unlock()
        observerRegistry?.stopMonitoring(pid: pid)
        // Drain in-flight syncs; any capture already past the guard has finished
        // applying before the barrier returns, so removeApp is the final word.
        syncQueue.sync {}
        model.removeApp(appKey: key)
    }

    // MARK: - Event-driven path (DirtyTracker + IncrementalSync)

    public func markDirty(pid: Int32) {
        let key = "pid:\(pid)"
        lock.lock()
        guard infos[key] != nil else {
            lock.unlock()
            return
        }
        dirty.insert(key)
        scheduleDebounceLocked()
        lock.unlock()
    }

    /// Window-level dirty hint: prefers a subtree capture of the window at
    /// `rect` (falls back to full capture when the window can't be matched).
    public func markWindowDirty(pid: Int32, rect: CGRect?) {
        let key = "pid:\(pid)"
        lock.lock()
        guard infos[key] != nil else {
            lock.unlock()
            return
        }
        if let rect {
            let norm = CoordinateComputer(screen: screen).screenNorm(rect)
            var rects = pendingWindowRects[key] ?? []
            if !rects.contains(where: { ($0.centerX - norm.centerX).magnitude < 0.01
                && ($0.centerY - norm.centerY).magnitude < 0.01 }) {
                rects.append(norm)
            }
            pendingWindowRects[key] = rects
        } else {
            dirty.insert(key)
        }
        scheduleDebounceLocked()
        lock.unlock()
    }

    private func scheduleDebounceLocked() {
        if let pending = pendingDebounce {
            pending.cancel()
        }
        let work = DispatchWorkItem { [weak self] in self?.flushDirty() }
        pendingDebounce = work
        debounceQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func flushDirty() {
        lock.lock()
        let keys = Array(dirty)
        dirty.removeAll()
        let pendingRects = pendingWindowRects
        pendingWindowRects.removeAll()
        pendingDebounce = nil
        let appInfos = keys.compactMap { self.infos[$0] }
        lock.unlock()

        for info in appInfos {
            syncApp(info: info)
        }
        for (key, rects) in pendingRects {
            lock.lock()
            let info = infos[key]
            lock.unlock()
            guard let info else { continue }
            syncWindow(info: info, rects: rects)
        }
    }

    // MARK: - Reconciliation backstop

    private func startReconciler() {
        let timer = DispatchSource.makeTimerSource(queue: debounceQueue)
        timer.schedule(deadline: .now() + reconciliationInterval, repeating: reconciliationInterval)
        timer.setEventHandler { [weak self] in self?.reconcile() }
        timer.resume()
        reconcilerTimer = timer
    }

    /// Re-reads the screen geometry via `screenReader` (called each reconcile
    /// tick so display changes don't stale normalization).
    public func refreshScreen() {
        if let reader = screenReader {
            screen = reader()
        }
    }

    /// Display reconfiguration hook (M3): the normalization base changed, so
    /// every cached entity rect is stale — refresh the screen info and mark
    /// all apps dirty (debounce coalesces them into one capture pass).
    public func displaysDidReconfigure() {
        refreshScreen()
        lock.lock()
        let pids = infos.values.map(\.pid)
        lock.unlock()
        for pid in pids {
            markDirty(pid: pid)
        }
    }

    private func reconcile() {
        refreshScreen()
        let now = Date()
        lock.lock()
        let due = infos.values.filter { info in
            // Cooling-down apps are skipped here instead of burning a batch
            // slot just to be dropped by the capture gate.
            if let cooldown = cooldownUntil[info.appKey], cooldown > now { return false }
            guard let last = lastCaptured[info.appKey] else { return true }
            return last.addingTimeInterval(reconciliationInterval) < now
        }
        let batch = Self.selectReconcileBatch(
            due: due,
            lastCaptured: lastCaptured,
            totalMonitored: infos.count,
            interval: reconciliationInterval,
            sweepTarget: reconcileSweepTarget,
            minBatch: reconcileBatch
        )
        lock.unlock()
        for info in batch {
            syncApp(info: info)
        }
    }

    /// Staleness-ordered batch selection: least-recently-captured apps first
    /// (name order gave no rotation guarantees), and the batch adapts to the
    /// monitored-app count so a full sweep stays within `sweepTarget`.
    static func selectReconcileBatch(
        due: [AppInfo],
        lastCaptured: [String: Date],
        totalMonitored: Int,
        interval: TimeInterval,
        sweepTarget: TimeInterval,
        minBatch: Int
    ) -> [AppInfo] {
        let sorted = due.sorted {
            (lastCaptured[$0.appKey] ?? .distantPast) < (lastCaptured[$1.appKey] ?? .distantPast)
        }
        let ticksPerSweep = max(1, Int((sweepTarget / max(interval, 0.001)).rounded(.down)))
        let adaptive = Int(ceil(Double(totalMonitored) / Double(ticksPerSweep)))
        return Array(sorted.prefix(max(minBatch, adaptive)))
    }

    // MARK: - Capture & apply

    private func syncApp(info: AppInfo) {
        let item = DispatchWorkItem { [weak self] in
            self?.captureAndApply(info: info)
        }
        syncQueue.async(execute: item)
    }

    private func captureAndApply(info: AppInfo) {
        lock.lock()
        guard infos[info.appKey] != nil, shouldCaptureLocked(info.appKey) else {
            lock.unlock()
            return
        }
        lock.unlock()

        var snapshot = capturer.snapshot(pid: info.pid, appKey: info.appKey)
        snapshot.appName = info.name
        let now = Date()

        lock.lock()
        guard infos[info.appKey] != nil else {
            lock.unlock()
            return
        }
        lastCaptured[info.appKey] = now
        if snapshot.error != nil || snapshot.elapsed >= 1.0 {
            // Unresponsive or erroring app: back off so we don't hammer it.
            cooldownUntil[info.appKey] = now.addingTimeInterval(cooldownOnError)
        }
        lock.unlock()

        if let error = snapshot.error {
            let status: SyncStatus = (error == .permissionDenied) ? .permissionDenied : .unavailable
            model.setStatus(appKey: info.appKey, pid: info.pid, status)
            return
        }

        let output = Pipeline(screen: screen, gridSize: indexGridSize, computeRelations: computeRelations).process(snapshot)
        // Heuristic ID stabilization: reuse the previous capture's ids for
        // elements that provably didn't change, so client references survive
        // full re-captures even when the AX tree path shifted.
        let remapped: PipelineOutput
        if let previous = model.output(appKey: info.appKey) {
            let map = IDStabilizer.stabilize(old: previous.entities, new: output.entities)
            remapped = output.remapped(by: map)
        } else {
            remapped = output
        }

        let meta = AppSnapshot(
            appKey: info.appKey, pid: info.pid,
            bundleID: info.bundleID, name: info.name,
            status: .warming, capturedAt: now, entityCount: 0,
            cgWindowCount: remapped.cgWindowCount > 0 ? remapped.cgWindowCount : nil,
            axWindowCount: remapped.axWindowCount > 0 ? remapped.axWindowCount : nil,
            missingWindowTitles: remapped.missingWindowTitles.isEmpty ? nil : remapped.missingWindowTitles
        )
        model.upsert(appKey: info.appKey, output: remapped, meta: meta, truncated: snapshot.truncated)
    }

    /// Throttling gate: skip if recently captured, or cooling down after errors.
    private func shouldCaptureLocked(_ key: String) -> Bool {
        let now = Date()
        if let cooldown = cooldownUntil[key], cooldown > now { return false }
        if let last = lastCaptured[key], now.timeIntervalSince(last) < minCaptureInterval {
            return false
        }
        return true
    }

    // MARK: - Per-window subtree capture

    private func syncWindow(info: AppInfo, rects: [NormRect]) {
        let item = DispatchWorkItem { [weak self] in
            self?.captureWindow(info: info, rects: rects)
        }
        syncQueue.async(execute: item)
    }

    private func captureWindow(info: AppInfo, rects: [NormRect]) {
        lock.lock()
        guard infos[info.appKey] != nil, shouldCaptureLocked(info.appKey) else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let previous = model.output(appKey: info.appKey) else { return }
        let oldWindows = previous.entities.filter { $0.role == "AXWindow" }
        guard !oldWindows.isEmpty else { return }

        var handled = Set<String>()
        for rect in rects {
            let candidates = oldWindows.filter { !handled.contains($0.id) }
            guard let match = candidates.min(by: { distanceFrom($0, to: rect) < distanceFrom($1, to: rect) }),
                  distanceFrom(match, to: rect) < 0.05 else { continue }
            guard let path = parsePath(from: match.id) else { continue }
            handled.insert(match.id)
            captureSubtree(info: info, windowID: match.id, path: path)
        }
    }

    private func captureSubtree(info: AppInfo, windowID: String, path: [Int]) {
        var subtree = capturer.snapshotWindow(pid: info.pid, appKey: info.appKey, path: path)
        subtree?.appName = info.name
        guard let subtree else {
            // Window resolution failed → full capture as fallback.
            syncApp(info: info)
            return
        }
        let now = Date()
        lock.lock()
        guard infos[info.appKey] != nil else {
            lock.unlock()
            return
        }
        lastCaptured[info.appKey] = now
        lock.unlock()

        guard subtree.error == nil else { return }
        let output = Pipeline(screen: screen, gridSize: indexGridSize, computeRelations: computeRelations).process(subtree)
        guard let previous = model.output(appKey: info.appKey) else { return }

        let merged = mergeWindow(previous: previous, subtree: output, windowID: windowID)
        let map = IDStabilizer.stabilize(old: previous.entities, new: merged.entities)
        let remapped = merged.remapped(by: map)

        let meta = AppSnapshot(
            appKey: info.appKey, pid: info.pid,
            bundleID: info.bundleID, name: info.name,
            status: .warming, capturedAt: now, entityCount: 0,
            cgWindowCount: remapped.cgWindowCount > 0 ? remapped.cgWindowCount : nil,
            axWindowCount: remapped.axWindowCount > 0 ? remapped.axWindowCount : nil,
            missingWindowTitles: remapped.missingWindowTitles.isEmpty ? nil : remapped.missingWindowTitles
        )
        model.upsert(
            appKey: info.appKey, output: remapped, meta: meta,
            truncated: subtree.truncated || model.isTruncated(appKey: info.appKey)
        )
    }

    /// Replaces only the entities of `windowID` with the freshly captured
    /// subtree; every other window keeps its previous entities byte-identical.
    private func mergeWindow(previous: PipelineOutput, subtree: PipelineOutput, windowID: String) -> PipelineOutput {
        let keep = previous.entities.filter { $0.windowID != windowID }
        let entities = (keep + subtree.entities).sorted { $0.id < $1.id }
        let relations = computeRelations ? TopologyComputer().compute(entities: entities) : []
        return PipelineOutput(
            entities: entities,
            relations: relations,
            index: SpatialIndex.build(from: entities),
            cgWindowCount: previous.cgWindowCount,
            axWindowCount: previous.axWindowCount,
            missingWindowTitles: previous.missingWindowTitles
        )
    }

    private func distanceFrom(_ entity: Entity, to rect: NormRect) -> Double {
        let center = entity.geometry.screen
        let dx = center.centerX - rect.centerX
        let dy = center.centerY - rect.centerY
        return dx * dx + dy * dy
    }

    /// "pid:722:0-2-3" → [0, 2, 3]; nil for ids without a numeric path suffix.
    private func parsePath(from id: String) -> [Int]? {
        guard let suffix = id.split(separator: ":", maxSplits: 2).last else { return nil }
        let parts = suffix.split(separator: "-").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == suffix.split(separator: "-").count else { return nil }
        return parts
    }

    // MARK: - Status

    public struct EngineStatus: Codable, Sendable {
        public var monitoredApps: Int
        public var version: UInt64
        public var permissionGranted: Bool
    }

    public func status() -> EngineStatus {
        lock.lock()
        let count = infos.count
        lock.unlock()
        return EngineStatus(
            monitoredApps: count,
            version: model.version,
            permissionGranted: AXIsProcessTrusted()
        )
    }
}
