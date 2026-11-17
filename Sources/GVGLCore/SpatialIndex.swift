import Foundation

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

    /// Default is the product default (`0` = linear scan), NOT a grid size.
    /// An omitted argument must never silently change a frame's index shape:
    /// the daemon runs linear by default, so a `4` default would make every
    /// call site that forgets to pass the engine's gridSize quietly disagree
    /// with the configured value (that exact mismatch shipped twice before —
    /// V4.1 #5 `mergeWindow` and `IDStabilizer.remapped`).
    public static func build(from entities: [Entity], gridSize: Int = 0) -> SpatialIndex {
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

