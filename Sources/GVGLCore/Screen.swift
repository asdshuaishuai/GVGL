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

