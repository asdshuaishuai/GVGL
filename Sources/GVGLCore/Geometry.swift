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

    /// Screen Space norm rect -> Quartz physical pixel point (top-left origin).
    /// Conversion 3 in the design doc; ready for CGEvent/cliclick without flip.
    public func toPixels(centerOf rect: NormRect) -> (x: Double, y: Double) {
        (rect.centerX * screen.width, rect.centerY * screen.height)
    }
}
