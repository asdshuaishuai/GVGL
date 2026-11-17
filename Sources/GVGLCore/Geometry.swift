import Foundation

/// Coordinate transforms between Quartz pixels and GVGL's three normalized spaces.
///
/// Verified by M0 spike: AX positions are returned in Quartz global display
/// coordinates (top-left origin, Y grows down) — identical to CGWindow bounds.
/// Therefore NO Y-axis flip is applied anywhere.
public struct CoordinateComputer: Sendable {
    public let screen: ScreenInfo

    public init(screen: ScreenInfo) {
        self.screen = screen
    }

    /// Quartz pixel rect (top-left origin) -> Screen Space norm rect.
    /// Conversion 1 in the design doc (without the erroneous Y-flip).
    /// Main-display normalization per the original formulas; secondary-display
    /// elements naturally get negative/out-of-range coordinates.
    public func screenNorm(_ rect: CGRect) -> NormRect {
        guard screen.width > 0, screen.height > 0 else { return .zero }
        return NormRect(
            x: rect.minX / screen.width,
            y: rect.minY / screen.height,
            w: rect.width / screen.width,
            h: rect.height / screen.height
        )
    }

    /// Screen Space norm rect -> Window Space norm rect, relative to the window's
    /// own Screen Space rect. Conversion 2 in the design doc.
    public func windowNorm(_ element: NormRect, window: NormRect) -> NormRect {
        guard window.w > 0, window.h > 0 else { return element }
        return NormRect(
            x: (element.x - window.x) / window.w,
            y: (element.y - window.y) / window.h,
            w: element.w / window.w,
            h: element.h / window.h
        )
    }

    /// Quartz pixel rect -> Display Space norm rect (V5): relative to the
    /// physical display containing the element. Quadrant labels and per-display
    /// reasoning use this space; Screen Space stays global main-normalized so
    /// the execution path (`toPixels`) is unchanged.
    public func displayNorm(_ rect: CGRect, display: DisplayInfo) -> NormRect {
        guard display.width > 0, display.height > 0 else { return .zero }
        return NormRect(
            x: (rect.minX - display.x) / display.width,
            y: (rect.minY - display.y) / display.height,
            w: rect.width / display.width,
            h: rect.height / display.height
        )
    }

    /// Screen Space norm rect -> Quartz physical pixel point (top-left origin).
    /// Conversion 3 in the design doc; ready for CGEvent/cliclick without flip.
    public func toPixels(centerOf rect: NormRect) -> (x: Double, y: Double) {
        (rect.centerX * screen.width, rect.centerY * screen.height)
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

