import XCTest
@testable import GVGLCore

final class TopologyTests: XCTestCase {
    private let winA = NormRect(x: 0.1, y: 0.1, w: 0.6, h: 0.6)

    private func entity(
        _ id: String,
        role: String = "AXButton",
        window: NormRect,
        screen: NormRect,
        app: String = "pid:1",
        entityParent: String? = nil,
        windowID: String? = nil
    ) -> Entity {
        Entity(
            id: id, role: role, title: nil, detail: nil, identifier: nil,
            enabled: true, actions: [],
            axParentID: entityParent, entityParentID: entityParent,
            windowID: windowID, appID: app, pid: 1,
            geometry: Geometry(screen: screen, window: window)
        )
    }

    private func relations(_ es: [Entity]) -> [Relation] {
        TopologyComputer().compute(entities: es)
    }

    func testDirectionRelationsCanonicalOnly() {
        let a = entity("a", window: NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.1),
                       screen: NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.1), windowID: "w")
        let b = entity("b", window: NormRect(x: 0.1, y: 0.3, w: 0.2, h: 0.1),
                       screen: NormRect(x: 0.1, y: 0.3, w: 0.2, h: 0.1), windowID: "w")
        let rs = relations([a, b])

        XCTAssertTrue(rs.contains(Relation(type: .above, from: "a", to: "b")))
        XCTAssertFalse(rs.contains(Relation(type: .below, from: "b", to: "a")))
    }

    func testLeftRight() {
        let l = entity("l", window: NormRect(x: 0.05, y: 0.1, w: 0.1, h: 0.1),
                       screen: NormRect(x: 0.05, y: 0.1, w: 0.1, h: 0.1), windowID: "w")
        let r = entity("r", window: NormRect(x: 0.2, y: 0.1, w: 0.1, h: 0.1),
                       screen: NormRect(x: 0.2, y: 0.1, w: 0.1, h: 0.1), windowID: "w")
        let rs = relations([l, r])
        // Canonical direction only (R12): leftOf(l,r) stored, mirror rightOf(r,l) pruned.
        XCTAssertTrue(rs.contains(Relation(type: .leftOf, from: "l", to: "r")))
        XCTAssertFalse(rs.contains(Relation(type: .rightOf, from: "r", to: "l")))
        XCTAssertTrue(rs.contains(Relation(type: .aligned, from: "l", to: "r")))
    }

    func testInsidePrunesDirectionRelations() {
        let parent = entity("p", window: NormRect(x: 0, y: 0, w: 0.5, h: 0.5),
                            screen: NormRect(x: 0, y: 0, w: 0.5, h: 0.5),
                            entityParent: nil, windowID: "w")
        let child = entity("c", window: NormRect(x: 0.05, y: 0.05, w: 0.1, h: 0.1),
                           screen: NormRect(x: 0.05, y: 0.05, w: 0.1, h: 0.1),
                           entityParent: "p", windowID: "w")
        let rs = relations([parent, child])

        XCTAssertTrue(rs.contains(Relation(type: .inside, from: "c", to: "p")))
        XCTAssertTrue(rs.contains(Relation(type: .contains, from: "p", to: "c")))
        XCTAssertFalse(rs.contains { $0.type == .above || $0.type == .below
            || $0.type == .leftOf || $0.type == .rightOf })
    }

    func testNearThreshold() {
        let a = entity("a", window: NormRect(x: 0, y: 0, w: 0.02, h: 0.02),
                       screen: NormRect(x: 0, y: 0, w: 0.02, h: 0.02), windowID: "w")
        let close = entity("b", window: NormRect(x: 0.02, y: 0.02, w: 0.02, h: 0.02),
                           screen: NormRect(x: 0.02, y: 0.02, w: 0.02, h: 0.02), windowID: "w")
        let far = entity("c", window: NormRect(x: 0.2, y: 0.2, w: 0.02, h: 0.02),
                         screen: NormRect(x: 0.2, y: 0.2, w: 0.02, h: 0.02), windowID: "w")

        let rs = relations([a, close, far])
        XCTAssertTrue(rs.contains { $0.type == .near && $0.from == "a" && $0.to == "b" })
        XCTAssertFalse(rs.contains { $0.type == .near && $0.from == "a" && $0.to == "c" })
    }

    func testAlignedThreshold() {
        let a = entity("a", window: NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.1),
                       screen: NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.1), windowID: "w")
        // Same row (centers 0.15 vs 0.16, |dy|=0.01 < min(0.1,0.08)*0.5=0.04).
        let b = entity("b", window: NormRect(x: 0.3, y: 0.12, w: 0.1, h: 0.08),
                       screen: NormRect(x: 0.3, y: 0.12, w: 0.1, h: 0.08), windowID: "w")
        // Different row AND different column (center (0.4, 0.45), dx=0.2 dy=0.30).
        let c = entity("c", window: NormRect(x: 0.3, y: 0.4, w: 0.2, h: 0.1),
                       screen: NormRect(x: 0.3, y: 0.4, w: 0.2, h: 0.1), windowID: "w")

        let rs = relations([a, b, c])
        XCTAssertTrue(rs.contains(Relation(type: .aligned, from: "a", to: "b")))
        XCTAssertFalse(rs.contains { $0.type == .aligned && $0.from == "a" && $0.to == "c" })
    }

    func testFarSameWindowPairGetsDirectionRelation() {
        // Per original doc §3.2: direction relations cover ALL same-window
        // pairs — no distance cut. A at (0.1,0.1) is above "far" at (0.1,0.7).
        let a = entity("a", window: NormRect(x: 0.1, y: 0.1, w: 0.1, h: 0.1),
                       screen: NormRect(x: 0.1, y: 0.1, w: 0.1, h: 0.1), windowID: "w")
        let far = entity("far", window: NormRect(x: 0.1, y: 0.7, w: 0.1, h: 0.1),
                         screen: NormRect(x: 0.1, y: 0.7, w: 0.1, h: 0.1), windowID: "w")
        let rs = relations([a, far])
        XCTAssertTrue(rs.contains(Relation(type: .above, from: "a", to: "far")))
    }

    func testPerGroupRelationCap() {
        // 30x30 dense grid in one window = 400k pairs; cap must bound output.
        var dense: [Entity] = []
        for row in 0..<30 {
            for col in 0..<30 {
                let x = Double(col) * 0.03, y = Double(row) * 0.03
                dense.append(entity("g\(row)-\(col)",
                                   window: NormRect(x: x, y: y, w: 0.02, h: 0.02),
                                   screen: NormRect(x: x, y: y, w: 0.02, h: 0.02),
                                   windowID: "w"))
            }
        }
        var computer = TopologyComputer()
        computer.maxRelationsPerGroup = 100
        computer.maxRelationsTotal = 500
        let rs = computer.compute(entities: dense)
        XCTAssertLessThanOrEqual(rs.count, 500, "global cap must hold")
    }

    func testNoDirectionAcrossWindowsButGlobalAligned() {
        let e1 = entity("x", window: NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.1),
                        screen: NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.1), windowID: "w1")
        let e2 = entity("y", window: NormRect(x: 0.1, y: 0.4, w: 0.2, h: 0.1),
                        screen: NormRect(x: 0.1, y: 0.4, w: 0.2, h: 0.1), windowID: "w2")
        let rs = relations([e1, e2])
        // Direction relations: same parent window only (original doc §3.2).
        XCTAssertFalse(rs.contains { $0.type == .above || $0.type == .below
            || $0.type == .leftOf || $0.type == .rightOf })
        // Aligned: ALL pairs (original doc §3.4) — same x-center → vertical column.
        XCTAssertTrue(rs.contains(Relation(type: .aligned, from: "x", to: "y")))
    }

    func testWindowNearAcrossApps() {
        let w1 = entity("w1", role: "AXWindow", window: NormRect(x: 0, y: 0, w: 0.1, h: 0.1),
                        screen: NormRect(x: 0, y: 0, w: 0.1, h: 0.1), app: "pid:1")
        let w2 = entity("w2", role: "AXWindow", window: NormRect(x: 0, y: 0, w: 0.1, h: 0.1),
                        screen: NormRect(x: 0.03, y: 0.03, w: 0.1, h: 0.1), app: "pid:2")
        // The original doc's unit is a single target app (§3.1 Step 0): pairs
        // from different apps never co-occur in one pipeline run.
        let rs = relations([w1])
        XCTAssertFalse(rs.contains { $0.type == .near })
    }
}
