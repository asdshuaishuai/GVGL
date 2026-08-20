import XCTest
@testable import GVGLCore

final class IDStabilizerTests: XCTestCase {
    private func entity(
        _ id: String,
        role: String = "AXButton",
        title: String? = nil,
        window: NormRect = NormRect(x: 0.2, y: 0.2, w: 0.3, h: 0.3),
        screen: NormRect = NormRect(x: 0.2, y: 0.2, w: 0.3, h: 0.3),
        windowID: String? = "w1",
        app: String = "pid:1"
    ) -> Entity {
        Entity(
            id: id, role: role, title: title, detail: nil, identifier: nil,
            enabled: true, actions: ["AXPress"],
            axParentID: nil, entityParentID: windowID, windowID: windowID,
            appID: app, pid: 1,
            geometry: Geometry(screen: screen, window: window)
        )
    }

    func testStableWhenTreeShifts() {
        // Old frame: button at 0-2, textfield at 0-3.
        let old = [
            entity("pid:1:0", role: "AXWindow", title: "main",
                   screen: NormRect(x: 0.1, y: 0.1, w: 0.8, h: 0.8)),
            entity("pid:1:0-2", title: "登录", window: NormRect(x: 0.2, y: 0.2, w: 0.1, h: 0.05)),
            entity("pid:1:0-3", role: "AXTextField", title: "username",
                   window: NormRect(x: 0.2, y: 0.4, w: 0.2, h: 0.05)),
        ]
        // New frame: an element was inserted above → button path shifted to 0-4,
        // textfield shifted to 0-5. Same titles, same positions.
        let new = [
            entity("pid:1:0", role: "AXWindow", title: "main",
                   screen: NormRect(x: 0.1, y: 0.1, w: 0.8, h: 0.8)),
            entity("pid:1:0-4", title: "登录", window: NormRect(x: 0.2, y: 0.2, w: 0.1, h: 0.05)),
            entity("pid:1:0-5", role: "AXTextField", title: "username",
                   window: NormRect(x: 0.2, y: 0.4, w: 0.2, h: 0.05)),
        ]

        let map = IDStabilizer.stabilize(old: old, new: new)
        XCTAssertEqual(map["pid:1:0-4"], "pid:1:0-2")
        XCTAssertEqual(map["pid:1:0-5"], "pid:1:0-3")
        XCTAssertNil(map["pid:1:0"], "window id identical across captures must not be remapped")
    }

    func testAmbiguousMatchKeepsNewID() {
        // Two identical buttons (same title, same position context) → ambiguous.
        let old = [
            entity("pid:1:0-1", title: "a", window: NormRect(x: 0.1, y: 0.1, w: 0.05, h: 0.05)),
            entity("pid:1:0-2", title: "a", window: NormRect(x: 0.1, y: 0.1, w: 0.05, h: 0.05)),
        ]
        let new = [
            entity("pid:1:0-5", title: "a", window: NormRect(x: 0.1, y: 0.1, w: 0.05, h: 0.05)),
        ]
        let map = IDStabilizer.stabilize(old: old, new: new)
        XCTAssertTrue(map.isEmpty, "ambiguous match must not steal an id")
    }

    func testTitlelessPositionalMatch() {
        let old = [
            entity("pid:1:0-7", window: NormRect(x: 0.2, y: 0.2, w: 0.05, h: 0.05)),
        ]
        let new = [
            entity("pid:1:0-9", window: NormRect(x: 0.21, y: 0.2, w: 0.05, h: 0.05)),
        ]
        let map = IDStabilizer.stabilize(old: old, new: new)
        XCTAssertEqual(map["pid:1:0-9"], "pid:1:0-7")
    }

    func testMovedFarAwayNotMatched() {
        let old = [
            entity("pid:1:0-2", title: "登录", window: NormRect(x: 0.2, y: 0.2, w: 0.1, h: 0.05)),
        ]
        let new = [
            entity("pid:1:0-3", title: "登录", window: NormRect(x: 0.7, y: 0.7, w: 0.1, h: 0.05)),
        ]
        let map = IDStabilizer.stabilize(old: old, new: new)
        XCTAssertTrue(map.isEmpty, "a far-away same-title element is a different element")
    }

    func testRemappedOutputConsistency() {
        let oldEntities = [
            entity("pid:1:0-2", title: "登录"),
            entity("pid:1:0-3", role: "AXTextField", title: "username"),
        ]
        let newEntities = [
            entity("pid:1:0-4", title: "登录"),
            entity("pid:1:0-5", role: "AXTextField", title: "username"),
        ]
        let map = IDStabilizer.stabilize(old: oldEntities, new: newEntities)

        let relations = [
            Relation(type: .above, from: "pid:1:0-4", to: "pid:1:0-5"),
        ]
        let output = PipelineOutput(
            entities: newEntities,
            relations: relations,
            index: SpatialIndex.build(from: newEntities)
        )
        let remapped = output.remapped(by: map)

        XCTAssertEqual(remapped.entities.map(\.id), ["pid:1:0-2", "pid:1:0-3"])
        XCTAssertEqual(remapped.relations, [Relation(type: .above, from: "pid:1:0-2", to: "pid:1:0-3")])
        XCTAssertEqual(remapped.index.byRole["AXButton"], ["pid:1:0-2"])
        XCTAssertEqual(remapped.entities.first?.entityParentID, "w1")
    }

    /// V3 fix: re-keying must not drop the CG cross-check stats.
    func testRemappedPreservesCGStats() {
        let e = entity("pid:1:0", role: "AXWindow", windowID: nil)
        let output = PipelineOutput(
            entities: [e],
            relations: [],
            index: SpatialIndex.build(from: [e]),
            cgWindowCount: 3, axWindowCount: 2, missingWindowTitles: ["孤窗"]
        )
        let remapped = output.remapped(by: ["pid:1:0": "pid:1:9"])
        XCTAssertEqual(remapped.cgWindowCount, 3)
        XCTAssertEqual(remapped.axWindowCount, 2)
        XCTAssertEqual(remapped.missingWindowTitles, ["孤窗"])
    }
}
