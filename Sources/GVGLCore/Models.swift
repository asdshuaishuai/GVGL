import Foundation

// MARK: - Screen

/// One physical display in Quartz global coordinates (top-left origin).
public struct DisplayInfo: Codable, Hashable, Sendable {
    public var id: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var scaleFactor: Double

    public init(id: Int, x: Double, y: Double, width: Double, height: Double, scaleFactor: Double = 1.0) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
    }

    public var center: (x: Double, y: Double) { (x + width / 2, y + height / 2) }

    public func contains(_ px: CGPoint) -> Bool {
        px.x >= x && px.x < x + width && px.y >= y && px.y < y + height
    }
}

public struct ScreenInfo: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public var scaleFactor: Double
    /// All online displays; the main display comes first. Empty in
    /// single-display configurations recorded before V1.6.
    public var displays: [DisplayInfo]

    public init(width: Double, height: Double, scaleFactor: Double = 1.0, displays: [DisplayInfo] = []) {
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.displays = displays
    }

    enum CodingKeys: String, CodingKey { case width, height, scaleFactor, displays }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        scaleFactor = try c.decodeIfPresent(Double.self, forKey: .scaleFactor) ?? 1.0
        displays = try c.decodeIfPresent([DisplayInfo].self, forKey: .displays) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(scaleFactor, forKey: .scaleFactor)
        try c.encode(displays, forKey: .displays)
    }
}

// MARK: - Normalized rect

/// Normalized rectangle in [0,1] x [0,1], top-left origin (Quartz style, Y grows down).
public struct NormRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public static let zero = NormRect(x: 0, y: 0, w: 0, h: 0)
    public static let unit = NormRect(x: 0, y: 0, w: 1, h: 1)

    public var centerX: Double { x + w / 2 }
    public var centerY: Double { y + h / 2 }
    public var area: Double { w * h }
    public var aspect: Double { h == 0 ? 1 : w / h }
    public var isEmpty: Bool { w <= 0 || h <= 0 }

    public func inset(by m: Double) -> NormRect {
        NormRect(x: x + m, y: y + m, w: w - 2 * m, h: h - 2 * m)
    }
}

// MARK: - Spatial labels

/// Four quadrants, computed from the entity center in Display Space (V5:
/// per-display quadrants — the space a human sees the element in).
public enum Region: String, Codable, Hashable, Sendable, CaseIterable {
    case q1, q2, q3, q4

    public static func of(centerX: Double, centerY: Double) -> Region {
        if centerY < 0.5 {
            return centerX < 0.5 ? .q1 : .q2
        }
        return centerX < 0.5 ? .q3 : .q4
    }
}

/// Nine-grid cell, computed from the entity center in Display Space (V5).
public enum Region9: String, Codable, Hashable, Sendable, CaseIterable {
    case leftTop, centerTop, rightTop
    case leftCenter, centerCenter, rightCenter
    case leftBottom, centerBottom, rightBottom

    public static func of(centerX: Double, centerY: Double) -> Region9 {
        let hz: Region9
        if centerX < 1.0 / 3.0 {
            hz = .leftTop
        } else if centerX < 2.0 / 3.0 {
            hz = .centerTop
        } else {
            hz = .rightTop
        }
        if centerY < 1.0 / 3.0 {
            return hz
        } else if centerY < 2.0 / 3.0 {
            return Region9(rawValue: hz.rawValue.replacingOccurrences(of: "Top", with: "Center"))!
        }
        return Region9(rawValue: hz.rawValue.replacingOccurrences(of: "Top", with: "Bottom"))!
    }
}

// MARK: - Geometry

public struct Geometry: Codable, Hashable, Sendable {
    public var screen: NormRect
    public var window: NormRect
    /// Rect relative to the nearest entity ancestor (entityParentID), in the
    /// parent's normalized coordinate system; unit rect when the entity has
    /// no entity parent (window roots, menu-bar roots, orphans).
    public var local: NormRect
    /// V5 Display Space: rect relative to the physical display containing the
    /// element (per-display normalization). Equals `screen` when the screen
    /// carries no display info (single-display recordings, synthetic tests).
    /// Spatial labels (`region`/`region9`) derive from THIS space so quadrants
    /// are correct on every display — main-screen normalization made every
    /// secondary-display element "q1/q3" garbage.
    public var display: NormRect
    public var centerX: Double
    public var centerY: Double
    public var area: Double
    public var aspect: Double
    public var region: Region
    public var region9: Region9

    public init(screen: NormRect, window: NormRect, local: NormRect = .unit, display: NormRect? = nil) {
        self.screen = screen
        self.window = window
        self.local = local
        self.display = display ?? screen
        self.centerX = screen.centerX
        self.centerY = screen.centerY
        self.area = screen.area
        self.aspect = screen.aspect
        // Quadrants describe where a human sees the element — that is inside
        // its own display, not in main-screen-normalized global space.
        self.region = Region.of(centerX: self.display.centerX, centerY: self.display.centerY)
        self.region9 = Region9.of(centerX: self.display.centerX, centerY: self.display.centerY)
    }

    enum CodingKeys: String, CodingKey {
        case screen, window, local, display
        case centerX, centerY, area, aspect, region, region9
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screen = try c.decode(NormRect.self, forKey: .screen)
        window = try c.decode(NormRect.self, forKey: .window)
        local = try c.decodeIfPresent(NormRect.self, forKey: .local) ?? .unit
        // Pre-V5 frames carry no display space → screen space (their region
        // labels were computed that way, so semantics round-trip).
        let decodedDisplay = try c.decodeIfPresent(NormRect.self, forKey: .display) ?? screen
        display = decodedDisplay
        centerX = try c.decode(Double.self, forKey: .centerX)
        centerY = try c.decode(Double.self, forKey: .centerY)
        area = try c.decode(Double.self, forKey: .area)
        aspect = try c.decode(Double.self, forKey: .aspect)
        region = try c.decode(Region.self, forKey: .region)
        region9 = try c.decode(Region9.self, forKey: .region9)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(screen, forKey: .screen)
        try c.encode(window, forKey: .window)
        try c.encode(local, forKey: .local)
        try c.encode(display, forKey: .display)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(area, forKey: .area)
        try c.encode(aspect, forKey: .aspect)
        try c.encode(region, forKey: .region)
        try c.encode(region9, forKey: .region9)
    }
}

// MARK: - Entity

public struct Entity: Codable, Hashable, Sendable {
    public var id: String
    public var role: String
    public var title: String?
    public var detail: String?
    public var identifier: String?
    /// AXValue coerced to a short string (≤512 chars): text-field contents,
    /// checkbox/slider state, tab label… nil when the element has no value
    /// or the value duplicates the title (dedup keeps frames lean).
    public var value: String?
    public var subrole: String?
    /// AXFocused — the element currently holding keyboard focus.
    public var focused: Bool
    /// AXSelected — e.g. the selected tab/row.
    public var selected: Bool
    /// AXPlaceholderValue — hint text of empty input fields.
    public var placeholder: String?
    public var enabled: Bool
    public var actions: [String]
    /// AX-tree parent node id (may be a non-entity node such as AXGroup).
    public var axParentID: String?
    /// Nearest ancestor that is itself an entity; the basis of `inside`.
    public var entityParentID: String?
    /// Owning window entity id, if any.
    public var windowID: String?
    /// Owning application key ("pid:NNN").
    public var appID: String
    public var pid: Int32
    /// Owning application display name (localizedName), e.g. "Microsoft Edge".
    public var appName: String?
    /// Physical display this entity lives on (id into screen.displays).
    /// nil when no display matched (falls back to main-display semantics).
    public var displayID: Int?
    /// Global front-to-back rank among on-screen windows (0 = frontmost);
    /// only set on window entities, nil when off-screen/unmatched.
    public var zIndex: Int?
    public var geometry: Geometry
    /// V4 scene graph: child entities when this node is materialized as part
    /// of a scene tree; nil in flat contexts (pipeline output, client-side
    /// flattened lists). Omitted from JSON when nil.
    public var children: [Entity]?
    /// V4: set when a depth-limited frame pruned this node's children
    /// (children then nil; the value is the direct-child count).
    public var prunedChildCount: Int?

    public init(
        id: String,
        role: String,
        title: String?,
        detail: String?,
        identifier: String?,
        value: String? = nil,
        subrole: String? = nil,
        focused: Bool = false,
        selected: Bool = false,
        placeholder: String? = nil,
        enabled: Bool,
        actions: [String],
        axParentID: String?,
        entityParentID: String?,
        windowID: String?,
        appID: String,
        pid: Int32,
        appName: String? = nil,
        displayID: Int? = nil,
        zIndex: Int? = nil,
        geometry: Geometry,
        children: [Entity]? = nil,
        prunedChildCount: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.detail = detail
        self.identifier = identifier
        self.value = value
        self.subrole = subrole
        self.focused = focused
        self.selected = selected
        self.placeholder = placeholder
        self.enabled = enabled
        self.actions = actions
        self.axParentID = axParentID
        self.entityParentID = entityParentID
        self.windowID = windowID
        self.appID = appID
        self.pid = pid
        self.appName = appName
        self.displayID = displayID
        self.zIndex = zIndex
        self.geometry = geometry
        self.children = children
        self.prunedChildCount = prunedChildCount
    }

    enum CodingKeys: String, CodingKey {
        case id, role, title, detail, identifier, value, subrole, focused, selected
        case placeholder, enabled, actions, axParentID, entityParentID, windowID
        case appID, pid, appName, displayID, zIndex, geometry, children, prunedChildCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        // V3 fields: absent in pre-expansion frames → safe defaults.
        value = try c.decodeIfPresent(String.self, forKey: .value)
        subrole = try c.decodeIfPresent(String.self, forKey: .subrole)
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        actions = try c.decode([String].self, forKey: .actions)
        axParentID = try c.decodeIfPresent(String.self, forKey: .axParentID)
        entityParentID = try c.decodeIfPresent(String.self, forKey: .entityParentID)
        windowID = try c.decodeIfPresent(String.self, forKey: .windowID)
        appID = try c.decode(String.self, forKey: .appID)
        pid = try c.decode(Int32.self, forKey: .pid)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        displayID = try c.decodeIfPresent(Int.self, forKey: .displayID)
        zIndex = try c.decodeIfPresent(Int.self, forKey: .zIndex)
        geometry = try c.decode(Geometry.self, forKey: .geometry)
        children = try c.decodeIfPresent([Entity].self, forKey: .children)
        prunedChildCount = try c.decodeIfPresent(Int.self, forKey: .prunedChildCount)
    }
}

public extension Entity {
    /// Convenience initializer without app-name/display info (legacy call sites).
    init(
        id: String,
        role: String,
        title: String?,
        detail: String?,
        identifier: String?,
        enabled: Bool,
        actions: [String],
        axParentID: String?,
        entityParentID: String?,
        windowID: String?,
        appID: String,
        pid: Int32,
        geometry: Geometry
    ) {
        self.init(
            id: id, role: role, title: title, detail: detail, identifier: identifier,
            enabled: enabled, actions: actions, axParentID: axParentID,
            entityParentID: entityParentID, windowID: windowID, appID: appID,
            pid: pid, appName: nil, displayID: nil, geometry: geometry
        )
    }
}

// MARK: - Relation

public enum RelationType: String, Codable, Hashable, Sendable, CaseIterable {
    case above, below, leftOf, rightOf, inside, contains, near, aligned
}

public struct Relation: Codable, Hashable, Sendable {
    public var type: RelationType
    public var from: String
    public var to: String
    /// Present for `near`: normalized Euclidean distance.
    public var distance: Double?

    public init(type: RelationType, from: String, to: String, distance: Double? = nil) {
        self.type = type
        self.from = from
        self.to = to
        self.distance = distance
    }
}

// MARK: - Spatial index

/// Spatial index serialized into frames for client-side pre-filtering.
/// `byRegion`/`byRole`/`byWindow`/`byApp` are linear-scan lookups (V1);
/// `byGrid` is a finer spatial hash (V2): cell key "r{row}c{col}" with
/// `gridSize` rows/cols over normalized [0,1] screen space (clamped).
public struct SpatialIndex: Codable, Hashable, Sendable {
    public var byRegion: [String: [String]]
    public var byRole: [String: [String]]
    public var byWindow: [String: [String]]
    public var byApp: [String: [String]]
    public var byGrid: [String: [String]]
    public var gridSize: Int

    public init(
        byRegion: [String: [String]] = [:],
        byRole: [String: [String]] = [:],
        byWindow: [String: [String]] = [:],
        byApp: [String: [String]] = [:],
        byGrid: [String: [String]] = [:],
        gridSize: Int = 4
    ) {
        self.byRegion = byRegion
        self.byRole = byRole
        self.byWindow = byWindow
        self.byApp = byApp
        self.byGrid = byGrid
        self.gridSize = gridSize
    }

    enum CodingKeys: String, CodingKey {
        case byRegion, byRole, byWindow, byApp, byGrid, gridSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        byRegion = try c.decodeIfPresent([String: [String]].self, forKey: .byRegion) ?? [:]
        byRole = try c.decodeIfPresent([String: [String]].self, forKey: .byRole) ?? [:]
        byWindow = try c.decodeIfPresent([String: [String]].self, forKey: .byWindow) ?? [:]
        byApp = try c.decodeIfPresent([String: [String]].self, forKey: .byApp) ?? [:]
        byGrid = try c.decodeIfPresent([String: [String]].self, forKey: .byGrid) ?? [:]
        gridSize = try c.decodeIfPresent(Int.self, forKey: .gridSize) ?? 4
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(byRegion, forKey: .byRegion)
        try c.encode(byRole, forKey: .byRole)
        try c.encode(byWindow, forKey: .byWindow)
        try c.encode(byApp, forKey: .byApp)
        // Linear-scan mode (gridSize 0) serializes the original V1 frame shape:
        // no grid keys at all.
        if gridSize > 0 {
            try c.encode(byGrid, forKey: .byGrid)
            try c.encode(gridSize, forKey: .gridSize)
        }
    }

    /// Grid cell key containing a normalized (screen-space) center.
    public static func cellKey(centerX: Double, centerY: Double, gridSize: Int) -> String {
        let size = max(1, gridSize)
        let col = min(size - 1, max(0, Int(centerX * Double(size))))
        let row = min(size - 1, max(0, Int(centerY * Double(size))))
        return "r\(row)c\(col)"
    }

    public static func build(from entities: [Entity], gridSize: Int = 4) -> SpatialIndex {
        var idx = SpatialIndex(gridSize: gridSize)
        for e in entities {
            idx.byRegion[String(e.geometry.region.rawValue), default: []].append(e.id)
            idx.byRole[e.role, default: []].append(e.id)
            idx.byWindow[e.windowID ?? "nil", default: []].append(e.id)
            idx.byApp[e.appID, default: []].append(e.id)
            // gridSize 0 = linear-scan mode (V1 behavior, no grid buckets).
            if gridSize > 0 {
                let cell = cellKey(centerX: e.geometry.centerX, centerY: e.geometry.centerY, gridSize: gridSize)
                idx.byGrid[cell, default: []].append(e.id)
            }
        }
        idx.byRegion = idx.byRegion.mapValues { $0.sorted() }
        idx.byRole = idx.byRole.mapValues { $0.sorted() }
        idx.byWindow = idx.byWindow.mapValues { $0.sorted() }
        idx.byApp = idx.byApp.mapValues { $0.sorted() }
        idx.byGrid = idx.byGrid.mapValues { $0.sorted() }
        return idx
    }
}

/// The replaceable index builder seam (V2-1). The daemon's pipeline and frame
/// materialization go through this so the strategy can be swapped without
/// touching callers. R-Tree is deliberately not implemented: queries run
/// client-side by design, so the serialized frame index needs hash lookups
/// (region / role / grid), not a server-side spatial tree.
public protocol SpatialIndexBuilding: Sendable {
    func build(from entities: [Entity]) -> SpatialIndex
}

public struct GridIndexBuilder: SpatialIndexBuilding {
    public var gridSize: Int

    public init(gridSize: Int = 4) {
        self.gridSize = gridSize
    }

    public func build(from entities: [Entity]) -> SpatialIndex {
        SpatialIndex.build(from: entities, gridSize: gridSize)
    }
}

/// V1-compatible builder (region/role/window/app only, no grid).
public struct LinearScanIndexBuilder: SpatialIndexBuilding {
    public init() {}

    public func build(from entities: [Entity]) -> SpatialIndex {
        SpatialIndex.build(from: entities, gridSize: 0)
    }
}

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
        self.axWindowCount = axWindowCount
        self.missingWindowTitles = missingWindowTitles
    }

    enum CodingKeys: String, CodingKey {
        case appKey, pid, bundleID, name, status, capturedAt, entityCount
        case cgWindowCount, axWindowCount, missingWindowTitles
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

// MARK: - Desktop map (V5)

/// One display in the coarse agent map: global pixel rect plus a friendly
/// index (0 = main display). `id` is the CGDirectDisplayID that entity
/// `displayID` refers to.
public struct MapDisplay: Codable, Hashable, Sendable {
    public var id: Int
    public var index: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var scaleFactor: Double

    public init(id: Int, index: Int, x: Double, y: Double, width: Double, height: Double, scaleFactor: Double) {
        self.id = id
        self.index = index
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
    }
}

/// One top-level window in the coarse agent map, positioned in Display Space
/// with its quadrant labels — the agent's "minimap" entry before drilling
/// into `get_frame` for details.
public struct MapWindow: Codable, Hashable, Sendable {
    public var id: String
    public var appKey: String
    public var appName: String?
    public var title: String?
    /// Display index into DesktopMap.displays.
    public var display: Int
    /// Display Space rect (per-display normalized).
    public var rect: NormRect
    public var region: Region
    public var region9: Region9
    public var zIndex: Int?
    /// Window belongs to the frontmost application.
    public var frontmost: Bool

    public init(id: String, appKey: String, appName: String?, title: String?,
                display: Int, rect: NormRect, region: Region, region9: Region9,
                zIndex: Int?, frontmost: Bool) {
        self.id = id
        self.appKey = appKey
        self.appName = appName
        self.title = title
        self.display = display
        self.rect = rect
        self.region = region
        self.region9 = region9
        self.zIndex = zIndex
        self.frontmost = frontmost
    }
}

/// Coarse spatial map of the whole desktop (V5): displays + every top-level
/// window in Display Space with quadrant labels, front-to-back. KB-scale —
/// the agent's first fetch, before `get_frame?app=` / `?depth=` drill-downs.
public struct DesktopMap: Codable, Hashable, Sendable {
    public var version: UInt64
    public var displays: [MapDisplay]
    /// zIndex order (frontmost first); unmatched/off-screen windows last,
    /// id-sorted for determinism.
    public var windows: [MapWindow]
    public var frontmostApp: String?
    public var status: FrameStatus

    public init(version: UInt64, displays: [MapDisplay], windows: [MapWindow],
                frontmostApp: String?, status: FrameStatus) {
        self.version = version
        self.displays = displays
        self.windows = windows
        self.frontmostApp = frontmostApp
        self.status = status
    }
}

public extension GVGLFrame {
    /// Builds the coarse desktop map from a materialized frame. Pure — no AX
    /// calls; safe to derive from any cached frame.
    var desktopMap: DesktopMap {
        let mapDisplays: [MapDisplay]
        if screen.displays.isEmpty {
            mapDisplays = [MapDisplay(
                id: 0, index: 0, x: 0, y: 0,
                width: screen.width, height: screen.height,
                scaleFactor: screen.scaleFactor
            )]
        } else {
            mapDisplays = screen.displays.enumerated().map { index, d in
                MapDisplay(id: d.id, index: index, x: d.x, y: d.y,
                           width: d.width, height: d.height, scaleFactor: d.scaleFactor)
            }
        }
        let indexOfDisplayID = Dictionary(
            mapDisplays.map { ($0.id, $0.index) },
            uniquingKeysWith: { first, _ in first }
        )

        let windows = allEntities
            .filter { $0.role == "AXWindow" }
            .map { e in
                MapWindow(
                    id: e.id,
                    appKey: e.appID,
                    appName: e.appName,
                    title: e.title,
                    display: e.displayID.flatMap { indexOfDisplayID[$0] } ?? 0,
                    rect: e.geometry.display,
                    region: e.geometry.region,
                    region9: e.geometry.region9,
                    zIndex: e.zIndex,
                    frontmost: e.appID == frontmostApp
                )
            }
            .sorted {
                let za = $0.zIndex ?? Int.max
                let zb = $1.zIndex ?? Int.max
                return za == zb ? $0.id < $1.id : za < zb
            }

        return DesktopMap(
            version: version,
            displays: mapDisplays,
            windows: windows,
            frontmostApp: frontmostApp,
            status: status
        )
    }
}

// MARK: - JSON

public extension JSONEncoder {
    static var gvgl: JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        // No sortedKeys: struct property order is already deterministic, and
        // key sorting measurably slows large-frame serialization.
        return enc
    }
}

public extension JSONDecoder {
    static var gvgl: JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        return dec
    }
}
