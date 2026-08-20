import Foundation
import GVGLCore

/// In-memory resident virtual desktop model. Frames are read-only materialized
/// views of this model, never captured on demand.
public final class DesktopModel: @unchecked Sendable {
    private let lock = NSLock()
    private let versionCond = NSCondition()
    private var apps: [String: AppState] = [:]
    /// Monotonic version; bumped on every model mutation.
    public private(set) var version: UInt64 = 0
    /// Grid resolution for the aggregated frame index (V2-1, default 4×4;
    /// 0 = linear-scan mode).
    public var gridSize: Int = 0
    /// (version, appKey) change log; keeps track of what changed so clients can
    /// do incremental pulls. Capped ring; appKey "system" = structural change.
    private var changeLog: [(version: UInt64, appKey: String)] = []
    private let changeLogCapacity = 512
    /// Full materialization cache: identical (version, filter, screen, depth)
    /// requests skip aggregation/sort entirely (serialization is the only
    /// remaining cost). Invalidated implicitly by the version/screen keys.
    private struct MaterializedKey: Hashable {
        var version: UInt64
        var filterApp: String?
        var screen: ScreenInfo
        var depth: Int?
    }
    private var materialized: (key: MaterializedKey, frame: GVGLFrame)?

    public struct AppState {
        public var output: PipelineOutput
        public var meta: AppSnapshot
        public var truncated: Bool

        public init(output: PipelineOutput, meta: AppSnapshot, truncated: Bool) {
            self.output = output
            self.meta = meta
            self.truncated = truncated
        }
    }

    /// appKey of the frontmost application (tracked via NSWorkspace
    /// activation notifications; bumps the version like any mutation).
    public private(set) var frontmostAppKey: String?

    public init() {}

    /// Records the frontmost app; no-op when unchanged (no version churn).
    public func setFrontmost(appKey: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard frontmostAppKey != appKey else { return }
        frontmostAppKey = appKey
        bumpVersionLocked(appKey ?? "system")
    }

    public func upsert(appKey: String, output: PipelineOutput, meta: AppSnapshot, truncated: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        var m = meta
        m.entityCount = output.entities.count
        m.status = .synced
        apps[appKey] = AppState(output: output, meta: m, truncated: truncated)
        bumpVersionLocked(appKey)
    }

    public func setStatus(appKey: String, pid: Int32, _ status: SyncStatus) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = apps[appKey] else {
            // Error/placeholder path: create an empty state so the status is observable.
            let meta = AppSnapshot(
                appKey: appKey, pid: pid, bundleID: nil, name: nil,
                status: status, capturedAt: nil, entityCount: 0
            )
            apps[appKey] = AppState(output: .empty, meta: meta, truncated: false)
            bumpVersionLocked(appKey)
            return
        }
        state.meta.status = status
        apps[appKey] = state
        bumpVersionLocked(appKey)
    }

    @discardableResult
    public func removeApp(appKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard apps.removeValue(forKey: appKey) != nil else { return false }
        bumpVersionLocked("system")
        return true
    }

    /// Must be called with `lock` held.
    private func bumpVersionLocked(_ appKey: String) {
        version &+= 1
        changeLog.append((version, appKey))
        if changeLog.count > changeLogCapacity {
            changeLog.removeFirst(changeLog.count - changeLogCapacity)
        }
        versionCond.lock()
        versionCond.broadcast()
        versionCond.unlock()
    }

    public func meta(appKey: String) -> AppSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return apps[appKey]?.meta
    }

    public func output(appKey: String) -> PipelineOutput? {
        lock.lock()
        defer { lock.unlock() }
        return apps[appKey]?.output
    }

    public func isTruncated(appKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return apps[appKey]?.truncated ?? false
    }

    public var appKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return apps.keys.sorted()
    }

    // MARK: - Change notification (subscribe / incremental pulls)

    /// Blocks (up to `timeout`) until the model version exceeds `version`.
    /// Returns the new version, or nil on timeout.
    public func waitForVersion(after version: UInt64, timeout: TimeInterval) -> UInt64? {
        versionCond.lock()
        defer { versionCond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while self.version == version {
            guard versionCond.wait(until: deadline) else { break }
        }
        let current = self.version
        return current > version ? current : nil
    }

    /// App keys (deduped, in change order) whose data changed strictly after
    /// `version`.
    public func changedApps(after version: UInt64) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        return changeLog.compactMap { entry in
            guard entry.version > version else { return nil }
            return seen.insert(entry.appKey).inserted ? entry.appKey : nil
        }
    }

    public struct FrameResult {
        public var frame: GVGLFrame
        /// Apps changed since `since` (empty when `since` is nil).
        public var changedApps: [String]

        public init(frame: GVGLFrame, changedApps: [String]) {
            self.frame = frame
            self.changedApps = changedApps
        }
    }

    /// Materializes a frame from the current model. O(entities) — no AX calls.
    /// With `since` set, also reports which apps changed after that version.
    /// `depth` limits the scene-tree levels below each app root (V4).
    public func frameResult(screen: ScreenInfo, filterApp: String? = nil, since: UInt64? = nil, depth: Int? = nil) -> FrameResult {
        let frame = frame(screen: screen, filterApp: filterApp, depth: depth)
        let changed = since.map { changedApps(after: $0) } ?? []
        return FrameResult(frame: frame, changedApps: changed)
    }

    /// Materializes a frame from the current model. O(entities) — no AX calls.
    /// Identical (version, filter, screen, depth) requests hit the
    /// materialization cache; only JSON serialization remains.
    ///
    /// V4: the frame is a hierarchical scene — per-app roots (windows, menu
    /// bar, orphans) with children attached via entityParentID. Relations are
    /// no longer serialized; clients compute spatial relations geometrically
    /// on demand (same rules as TopologyComputer).
    public func frame(screen: ScreenInfo, filterApp: String? = nil, depth: Int? = nil) -> GVGLFrame {
        lock.lock()
        defer { lock.unlock() }

        let key = MaterializedKey(version: version, filterApp: filterApp, screen: screen, depth: depth)
        if let cached = materialized, cached.key == key {
            return cached.frame
        }

        let states: [AppState]
        if let filterApp {
            states = apps[filterApp].map { [$0] } ?? []
        } else {
            states = apps.sorted { $0.key < $1.key }.map(\.value)
        }

        // Scene tree per app; the index covers exactly what the frame
        // delivers (depth-pruned frames index the pruned set).
        var scene: [SceneApp] = []
        scene.reserveCapacity(states.count)
        for state in states {
            let roots = SceneTree.build(entities: state.output.entities, depth: depth)
            scene.append(SceneApp(
                appKey: state.meta.appKey,
                pid: state.meta.pid,
                bundleID: state.meta.bundleID,
                name: state.meta.name,
                status: state.meta.status,
                capturedAt: state.meta.capturedAt,
                entityCount: state.meta.entityCount,
                cgWindowCount: state.meta.cgWindowCount,
                axWindowCount: state.meta.axWindowCount,
                missingWindowTitles: state.meta.missingWindowTitles,
                children: roots
            ))
        }
        let flat = scene.flatMap { SceneTree.flatten($0.children) }
        let index = GridIndexBuilder(gridSize: gridSize).build(from: flat)

        let status: FrameStatus
        if states.isEmpty {
            status = .unavailable
        } else if states.contains(where: { $0.meta.status == .warming }) {
            status = .warming
        } else if states.contains(where: { $0.meta.status == .permissionDenied }) {
            status = .permissionDenied
        } else if states.contains(where: { $0.truncated }) {
            status = .partial
        } else {
            status = .ok
        }

        let now = Date()
        let frame = GVGLFrame(
            frameID: UUID().uuidString,
            version: version,
            createdAt: now,
            syncedAt: now,
            screen: screen,
            scene: scene,
            index: index,
            frontmostApp: frontmostAppKey,
            status: status
        )
        materialized = (key, frame)
        return frame
    }
}
