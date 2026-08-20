import XCTest
@testable import GVGLCore

final class CoordinateTests: XCTestCase {
    let screen = ScreenInfo(width: 3440, height: 1440)

    func testScreenNormNoFlip() {
        let c = CoordinateComputer(screen: screen)
        let topLeft = c.screenNorm(CGRect(x: 0, y: 0, width: 344, height: 144))
        XCTAssertEqual(topLeft.x, 0, accuracy: 1e-9)
        XCTAssertEqual(topLeft.y, 0, accuracy: 1e-9)
        XCTAssertEqual(topLeft.w, 0.1, accuracy: 1e-9)
        XCTAssertEqual(topLeft.h, 0.1, accuracy: 1e-9)

        // Quartz y=1296 is near the BOTTOM of the screen. No flip: norm y == 0.9.
        // (A Cocoa-style flip would produce 0.0 and is exactly the bug M0 disproved.)
        let bottom = c.screenNorm(CGRect(x: 0, y: 1296, width: 344, height: 144))
        XCTAssertEqual(bottom.y, 0.9, accuracy: 1e-9)
    }

    func testWindowNorm() {
        let c = CoordinateComputer(screen: screen)
        let win = NormRect(x: 0.2, y: 0.2, w: 0.6, h: 0.6)
        let elem = NormRect(x: 0.3, y: 0.3, w: 0.3, h: 0.3)
        let w = c.windowNorm(elem, window: win)
        XCTAssertEqual(w.x, 1.0 / 6, accuracy: 1e-9)
        XCTAssertEqual(w.y, 1.0 / 6, accuracy: 1e-9)
        XCTAssertEqual(w.w, 0.5, accuracy: 1e-9)
        XCTAssertEqual(w.h, 0.5, accuracy: 1e-9)
    }

    func testToPixels() {
        let c = CoordinateComputer(screen: screen)
        let (x, y) = c.toPixels(centerOf: NormRect(x: 0.49, y: 0.64, w: 0.02, h: 0.02))
        XCTAssertEqual(x, 0.5 * 3440, accuracy: 1e-6)
        XCTAssertEqual(y, 0.65 * 1440, accuracy: 1e-6)
    }

    func testRegion() {
        XCTAssertEqual(Region.of(centerX: 0.1, centerY: 0.1), .q1)
        XCTAssertEqual(Region.of(centerX: 0.9, centerY: 0.1), .q2)
        XCTAssertEqual(Region.of(centerX: 0.1, centerY: 0.9), .q3)
        XCTAssertEqual(Region.of(centerX: 0.9, centerY: 0.9), .q4)
    }

    func testRegion9() {
        XCTAssertEqual(Region9.of(centerX: 0.1, centerY: 0.1), .leftTop)
        XCTAssertEqual(Region9.of(centerX: 0.5, centerY: 0.5), .centerCenter)
        XCTAssertEqual(Region9.of(centerX: 0.9, centerY: 0.9), .rightBottom)
        XCTAssertEqual(Region9.of(centerX: 0.9, centerY: 0.1), .rightTop)
        XCTAssertEqual(Region9.of(centerX: 0.1, centerY: 0.9), .leftBottom)
    }

    func testDisplayInfoContains() {
        let d = DisplayInfo(id: 1, x: -1280, y: 0, width: 1280, height: 1440)
        XCTAssertTrue(d.contains(CGPoint(x: -640, y: 100)))
        XCTAssertFalse(d.contains(CGPoint(x: 100, y: 100)))
        XCTAssertFalse(d.contains(CGPoint(x: -2000, y: 100)))
    }

    func testSecondaryDisplayElementUsesMainScreenFormulas() {
        // Original doc §2.2 转换1: screen_norm = px / mainScreenSize, regardless
        // of which display the element is on (V1 = main screen only).
        let c = CoordinateComputer(screen: screen)
        let r = c.screenNorm(CGRect(x: -1000, y: 200, width: 100, height: 50))
        XCTAssertEqual(r.x, -1000.0 / 3440.0, accuracy: 1e-9)
        XCTAssertEqual(r.y, 200.0 / 1440.0, accuracy: 1e-9)
    }
}
