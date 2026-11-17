import Foundation

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

