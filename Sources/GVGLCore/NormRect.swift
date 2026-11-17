import Foundation

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

