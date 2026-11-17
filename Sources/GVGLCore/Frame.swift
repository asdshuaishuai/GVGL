import Foundation

// MARK: - App sync state

public enum SyncStatus: String, Codable, Hashable, Sendable {
    case synced
    case warming
    case unavailable
    case permissionDenied
    case stalled
}

public struct AppSnapshot: Codable, Hashable, Sendable {
    public var appKey: String
    public var pid: Int32
    public var bundleID: String?
    public var name: String?
    public var status: SyncStatus
    public var capturedAt: Date?
    public var entityCount: Int
    /// V2-3 CGWindow cross-check: on-screen CG window count seen by the probe.
    public var cgWindowCount: Int?
    /// AX action probes that ERRORED during the last capture. Present only
    /// when non-zero: it means `actions` in this app's subtree is incomplete
    /// for an unknown reason, rather than the elements genuinely having no
    /// actions. Zero-omitted keeps normal frames byte-identical.
    public var actionProbeFailures: Int?
    /// V2-3: AX window entity count (may exceed CG count: AX sees all Spaces).
    public var axWindowCount: Int?
    /// V2-3: CG window titles with no matching AX window (weak-AX signal).
    public var missingWindowTitles: [String]?

    public init(
        appKey: String,
        pid: Int32,
        bundleID: String?,
        name: String?,
        status: SyncStatus,
        capturedAt: Date?,
        entityCount: Int,
        cgWindowCount: Int? = nil,
        actionProbeFailures: Int? = nil,
        axWindowCount: Int? = nil,
        missingWindowTitles: [String]? = nil
    ) {
        self.appKey = appKey
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.status = status
        self.capturedAt = capturedAt
        self.entityCount = entityCount
        self.cgWindowCount = cgWindowCount
        self.actionProbeFailures = actionProbeFailures
        self.axWindowCount = axWindowCount
        self.missingWindowTitles = missingWindowTitles
    }

    enum CodingKeys: String, CodingKey {
        case appKey, pid, bundleID, name, status, capturedAt, entityCount
        case cgWindowCount, axWindowCount, missingWindowTitles, actionProbeFailures
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appKey = try c.decode(String.self, forKey: .appKey)
        pid = try c.decode(Int32.self, forKey: .pid)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        status = try c.decode(SyncStatus.self, forKey: .status)
        capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt)
        entityCount = try c.decode(Int.self, forKey: .entityCount)
        cgWindowCount = try c.decodeIfPresent(Int.self, forKey: .cgWindowCount)
        actionProbeFailures = try c.decodeIfPresent(Int.self, forKey: .actionProbeFailures)
        axWindowCount = try c.decodeIfPresent(Int.self, forKey: .axWindowCount)
        missingWindowTitles = try c.decodeIfPresent([String].self, forKey: .missingWindowTitles)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appKey, forKey: .appKey)
        try c.encode(pid, forKey: .pid)
        try c.encodeIfPresent(bundleID, forKey: .bundleID)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(capturedAt, forKey: .capturedAt)
        try c.encode(entityCount, forKey: .entityCount)
        try c.encodeIfPresent(cgWindowCount, forKey: .cgWindowCount)
        try c.encodeIfPresent(actionProbeFailures, forKey: .actionProbeFailures)
        try c.encodeIfPresent(axWindowCount, forKey: .axWindowCount)
        try c.encodeIfPresent(missingWindowTitles, forKey: .missingWindowTitles)
    }
}

// MARK: - Frame

public enum FrameStatus: String, Codable, Hashable, Sendable {
    case ok
    case warming
    case partial
    case permissionDenied
    case unavailable
}

/// V4 scene graph: one root per monitored app. `children` holds the app's
/// top-level entities (windows, menu bar, orphans) in natural AX order;
/// nesting carries the containment hierarchy that flat frames expressed via
/// entityParentID links.
public struct SceneApp: Codable, Hashable, Sendable {
    public var appKey: String
    public var pid: Int32
    public var bundleID: String?
    public var name: String?
    public var status: SyncStatus
    public var capturedAt: Date?
    public var entityCount: Int
    /// --cg-check diagnostics (nil when the probe's diagnostics are off).
    public var cgWindowCount: Int?
    /// AX action probes that ERRORED during the last capture. Present only
    /// when non-zero: it means `actions` in this app's subtree is incomplete
    /// for an unknown reason, rather than the elements genuinely having no
    /// actions. Zero is omitted so normal frames are unchanged.
    public var actionProbeFailures: Int?
    public var axWindowCount: Int?
    public var missingWindowTitles: [String]?
    public var children: [Entity]

    public init(
        appKey: String,
        pid: Int32,
        bundleID: String?,
        name: String?,
        status: SyncStatus,
        capturedAt: Date?,
        entityCount: Int,
        cgWindowCount: Int? = nil,
        actionProbeFailures: Int? = nil,
        axWindowCount: Int? = nil,
        missingWindowTitles: [String]? = nil,
        children: [Entity]
    ) {
        self.appKey = appKey
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.status = status
        self.capturedAt = capturedAt
        self.entityCount = entityCount
        self.cgWindowCount = cgWindowCount
        self.actionProbeFailures = actionProbeFailures
        self.axWindowCount = axWindowCount
        self.missingWindowTitles = missingWindowTitles
        self.children = children
    }
}

public struct GVGLFrame: Codable, Hashable, Sendable {
    public var frameID: String
    public var version: UInt64
    public var createdAt: Date
    public var syncedAt: Date
    public var screen: ScreenInfo
    /// Hierarchical scene (V4). Replaces the flat entities[]/relations[]
    /// arrays: containment is the tree itself, and spatial relations are
    /// computed client-side on demand (no more O(N²) relation payloads).
    public var scene: [SceneApp]
    public var index: SpatialIndex
    /// appKey ("pid:NNN") of the frontmost (active) application, if known.
    public var frontmostApp: String?
    public var status: FrameStatus

    public init(
        frameID: String,
        version: UInt64,
        createdAt: Date,
        syncedAt: Date,
        screen: ScreenInfo,
        scene: [SceneApp],
        index: SpatialIndex,
        frontmostApp: String? = nil,
        status: FrameStatus
    ) {
        self.frameID = frameID
        self.version = version
        self.createdAt = createdAt
        self.syncedAt = syncedAt
        self.screen = screen
        self.scene = scene
        self.index = index
        self.frontmostApp = frontmostApp
        self.status = status
    }
}

public extension GVGLFrame {
    /// All entities flattened from the scene tree in document order.
    var allEntities: [Entity] {
        scene.flatMap { SceneTree.flatten($0.children) }
    }
}

