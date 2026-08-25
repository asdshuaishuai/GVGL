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
    /// V5.1 quadrant-label hysteresis band (display-space fraction). An
    /// entity whose display-space center stays within this distance of a
    /// quadrant/9-grid boundary KEEPS its previous label across captures, so
    /// a window resting on a label edge doesn't flip q1↔q2 on every minor
    /// jitter. Rects stay exact — only the labels are sticky. 0 disables.
    public var regionHysteresis: Double = 0.02
    /// (version, appKey, regionBuckets) change log; keeps track of what
    /// changed so clients can do incremental pulls and region-masked
    /// subscriptions. Capped ring; appKey "system" = structural change.
    private struct ChangeEntry {
        var version: UInt64
        var appKey: String
        var regions: Set<String>
    }
    private var changeLog: [ChangeEntry] = []
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
    /// Logs the "sys" region bucket so region-masked subscriptions can opt
    /// into frontmost changes explicitly.
    public func setFrontmost(appKey: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard frontmostAppKey != appKey else { return }
        frontmostAppKey = appKey
        bumpVersionLocked(appKey ?? "system", regions: ["sys"])
    }

    public func upsert(appKey: String, output: PipelineOutput, meta: AppSnapshot, truncated: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let previous = apps[appKey]?.output.entities ?? []
        // Model-boundary invariant: one live entity per id. Any duplicate that
        // slips through a capture/merge path would corrupt the scene tree and
        // every id-keyed consumer (index, client lookups).
        var finalOutput = output
        var seen = Set<String>()
        seen.reserveCapacity(output.entities.count)
        let deduped = output.entities.filter { seen.insert($0.id).inserted }
        if deduped.count != output.entities.count {
            finalOutput = PipelineOutput(
                entities: deduped,
                relations: output.relations,
                index: SpatialIndex.build(from: deduped, gridSize: gridSize),
                cgWindowCount: output.cgWindowCount,
                axWindowCount: output.axWindowCount,
                missingWindowTitles: output.missingWindowTitles
            )
        }
        // V5.1: sticky quadrant labels near boundaries (spatial anchor
        // stability). Any adjustment forces an index rebuild (byRegion keys
        // on geometry.region).
        let (stabilized, didStabilize) = applyRegionHysteresis(
            to: finalOutput.entities, previous: previous
        )
        if didStabilize {
            finalOutput = PipelineOutput(
                entities: stabilized,
                relations: finalOutput.relations,
                index: SpatialIndex.build(from: stabilized, gridSize: gridSize),
                cgWindowCount: finalOutput.cgWindowCount,
                axWindowCount: finalOutput.axWindowCount,
                missingWindowTitles: finalOutput.missingWindowTitles
            )
        } else {
            finalOutput.entities = stabilized
        }
        var m = meta
        m.entityCount = finalOutput.entities.count
        m.status = .synced
        apps[appKey] = AppState(output: finalOutput, meta: m, truncated: truncated)
        bumpVersionLocked(appKey, regions: Self.changedRegionBuckets(previous: previous, current: stabilized))
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
        guard let state = apps.removeValue(forKey: appKey) else { return false }
        // The removed entities' buckets change too — log them so
        // region-masked subscriptions see the region emptying out.
        bumpVersionLocked("system", regions: Self.changedRegionBuckets(previous: state.output.entities, current: []))
        return true
    }

    /// Must be called with `lock` held.
    private func bumpVersionLocked(_ appKey: String, regions: Set<String> = []) {
        version &+= 1
        changeLog.append(ChangeEntry(version: version, appKey: appKey, regions: regions))
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

    /// Region buckets ("d<displayID>q<region>", e.g. "d1q2"; "sys" for
    /// frontmost changes) touched by changes strictly after `version`.
    /// Deduped, sorted — the union an agent needs when it masked a
    /// subscription to specific quadrants.
    public func changedRegions(after version: UInt64) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        for entry in changeLog where entry.version > version {
            seen.formUnion(entry.regions)
        }
        return seen.sorted()
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

    // MARK: - V5.1 region hysteresis & change buckets

    /// Bucket key for one entity: "d<displayID><region>" (region rawValue
    /// already carries its "q" prefix, e.g. "d1q2"). Entities without a
    /// display id bucket under display 0 (the synthesized main display of
    /// get_map).
    static func regionBucket(of e: Entity) -> String {
        "d\(e.displayID ?? 0)\(e.geometry.region.rawValue)"
    }

    /// Buckets touched by an app transition: added/changed entities bucket
    /// under their NEW position, removed entities under their old one.
    static func changedRegionBuckets(previous: [Entity], current: [Entity]) -> Set<String> {
        guard !(previous.isEmpty && current.isEmpty) else { return [] }
        let oldByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var buckets = Set<String>()
        for e in current {
            if let old = oldByID[e.id], old == e { continue } // byte-identical
            buckets.insert(regionBucket(of: e))
        }
        for old in previous where newByID[old.id] == nil {
            buckets.insert(regionBucket(of: old))
        }
        return buckets
    }

    /// Sticky labels: for entities that existed in `previous` (same id AND
    /// same display), a label flip is accepted only when the display-space
    /// center crossed the separating boundary by more than the hysteresis
    /// band. Returns the (possibly unchanged) list and whether anything was
    /// adjusted (adjustments require an index rebuild because byRegion keys
    /// on geometry.region).
    private func applyRegionHysteresis(to entities: [Entity], previous: [Entity]) -> ([Entity], Bool) {
        guard regionHysteresis > 0, !previous.isEmpty, !entities.isEmpty else { return (entities, false) }
        let oldByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let band = regionHysteresis
        var adjusted = false
        let result = entities.map { entity -> Entity in
            guard let old = oldByID[entity.id],
                  old.displayID == entity.displayID,
                  old.geometry.region != entity.geometry.region
                    || old.geometry.region9 != entity.geometry.region9 else { return entity }
            var e = entity
            let d = e.geometry.display
            // Axis indices: quadrant boundaries [0.5]; 9-grid [1/3, 2/3].
            let (oldQH, oldQV) = Self.quadrantAxes(of: old.geometry.region)
            let qh = Self.stableAxisIndex(previous: oldQH, value: d.centerX, boundaries: [0.5], band: band)
            let qv = Self.stableAxisIndex(previous: oldQV, value: d.centerY, boundaries: [0.5], band: band)
            if let region = Self.quadrant(h: qh, v: qv), region != e.geometry.region {
                e.geometry.region = region
                adjusted = true
            }
            let (oldGH, oldGV) = Self.gridAxes(of: old.geometry.region9)
            let gh = Self.stableAxisIndex(previous: oldGH, value: d.centerX, boundaries: [1.0 / 3.0, 2.0 / 3.0], band: band)
            let gv = Self.stableAxisIndex(previous: oldGV, value: d.centerY, boundaries: [1.0 / 3.0, 2.0 / 3.0], band: band)
            if let r9 = Self.grid9(h: gh, v: gv), r9 != e.geometry.region9 {
                e.geometry.region9 = r9
                adjusted = true
            }
            return e
        }
        return (result, adjusted)
    }

    /// Interval index of `value` under sorted `boundaries`, with hysteresis
    /// against `previous` (the previously stored label's axis index): a flip
    /// is accepted only when `value` moved past the separating boundary by
    /// more than `band`.
    private static func stableAxisIndex(previous: Int, value: Double, boundaries: [Double], band: Double) -> Int {
        func plain(_ v: Double) -> Int {
            var idx = 0
            for b in boundaries where v >= b { idx += 1 }
            return idx
        }
        let newIndex = plain(value)
        guard newIndex != previous else { return previous }
        // boundaries sorted; the one separating previous and new:
        let separator = boundaries[max(previous, newIndex) - 1]
        return (value - separator).magnitude < band ? previous : newIndex
    }

    private static func quadrantAxes(of r: Region) -> (h: Int, v: Int) {
        switch r {
        case .q1: return (0, 0)
        case .q2: return (1, 0)
        case .q3: return (0, 1)
        case .q4: return (1, 1)
        }
    }

    private static func quadrant(h: Int, v: Int) -> Region? {
        switch (h, v) {
        case (0, 0): return .q1
        case (1, 0): return .q2
        case (0, 1): return .q3
        case (1, 1): return .q4
        default: return nil
        }
    }

    private static let gridColumns = ["Left", "Center", "Right"]
    private static let gridRows = ["Top", "Center", "Bottom"]

    private static func gridAxes(of r: Region9) -> (h: Int, v: Int) {
        for (vi, row) in gridRows.enumerated() {
            for (hi, col) in gridColumns.enumerated() {
                if r.rawValue == col.lowercased() + row { return (hi, vi) }
            }
        }
        return (1, 1) // unreachable: every rawValue is in the table
    }

    private static func grid9(h: Int, v: Int) -> Region9? {
        guard gridColumns.indices.contains(h), gridRows.indices.contains(v) else { return nil }
        return Region9(rawValue: gridColumns[h].lowercased() + gridRows[v])
    }
}
