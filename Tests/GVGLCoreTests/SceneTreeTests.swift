import XCTest
@testable import GVGLCore

final class SceneTreeTests: XCTestCase {
    private func entity(
        _ id: String,
        role: String = "AXButton",
        parent: String? = nil
    ) -> Entity {
        Entity(
            id: id, role: role, title: nil, detail: nil, identifier: nil,
            enabled: true, actions: [],
            axParentID: nil, entityParentID: parent, windowID: nil,
            appID: "pid:1", pid: 1,
            geometry: Geometry(screen: .unit, window: .unit)
        )
    }

    /// window 0
    /// ├─ button 0-0
    /// │   └─ text 0-0-0
    /// └─ field 0-1
    /// menubar mb
    /// └─ item mb-0
    private func fixture() -> [Entity] {
        [
            entity("pid:1:0", role: "AXWindow"),
            entity("pid:1:0-0", parent: "pid:1:0"),
            entity("pid:1:0-0-0", role: "AXStaticText", parent: "pid:1:0-0"),
            entity("pid:1:0-1", role: "AXTextField", parent: "pid:1:0"),
            entity("pid:1:mb", role: "AXMenuBar"),
            entity("pid:1:mb-0", role: "AXMenuBarItem", parent: "pid:1:mb"),
        ]
    }

    func testBuildNestsViaEntityParentID() {
        let roots = SceneTree.build(entities: fixture())
        XCTAssertEqual(roots.map(\.id), ["pid:1:mb", "pid:1:0"],
                       "menu bar (mb prefix) sorts before window paths")
        let window = roots[1]
        XCTAssertEqual(window.children?.map(\.id), ["pid:1:0-0", "pid:1:0-1"])
        XCTAssertEqual(window.children?.first?.children?.map(\.id), ["pid:1:0-0-0"])
        XCTAssertEqual(roots[0].children?.map(\.id), ["pid:1:mb-0"])
    }

    func testNaturalPathOrdering() {
        // Lexicographic would order 0-10 before 0-2; natural must not.
        let entities = [
            entity("pid:1:0-10", parent: "pid:1:0"),
            entity("pid:1:0-2", parent: "pid:1:0"),
            entity("pid:1:0-1", parent: "pid:1:0"),
            entity("pid:1:0", role: "AXWindow"),
        ]
        let roots = SceneTree.build(entities: entities)
        XCTAssertEqual(roots.first?.children?.map(\.id), ["pid:1:0-1", "pid:1:0-2", "pid:1:0-10"])
    }

    func testOrphansAttachToRootLevel() {
        // Parent filtered out (budget caps) → child must not vanish.
        let orphan = entity("pid:1:0-9", parent: "pid:1:0") // no pid:1:0 in set
        let roots = SceneTree.build(entities: [orphan])
        XCTAssertEqual(roots.map(\.id), ["pid:1:0-9"])
        XCTAssertNil(roots.first?.children)
    }

    func testDepthPruning() {
        let depth1 = SceneTree.build(entities: fixture(), depth: 1)
        XCTAssertEqual(depth1.map(\.id), ["pid:1:mb", "pid:1:0"])
        XCTAssertNil(depth1[1].children)
        XCTAssertEqual(depth1[1].prunedChildCount, 2)
        XCTAssertEqual(depth1[0].prunedChildCount, 1)

        let depth2 = SceneTree.build(entities: fixture(), depth: 2)
        let window = depth2[1]
        XCTAssertEqual(window.children?.map(\.id), ["pid:1:0-0", "pid:1:0-1"])
        XCTAssertNil(window.children?.first?.children)
        XCTAssertEqual(window.children?.first?.prunedChildCount, 1)
        // Leaf nodes carry no pruning marker.
        XCTAssertNil(window.children?.last?.prunedChildCount)
    }

    func testFlattenRoundtrip() {
        let flat = SceneTree.flatten(SceneTree.build(entities: fixture()))
        XCTAssertEqual(Set(flat.map(\.id)), Set(fixture().map(\.id)),
                       "flatten must preserve every entity exactly once")
    }

    func testFrameSceneJSONRoundtrip() throws {
        let scene = SceneTree.build(entities: fixture())
        let frame = GVGLFrame(
            frameID: "t", version: 7, createdAt: Date(timeIntervalSince1970: 1000),
            syncedAt: Date(timeIntervalSince1970: 1000),
            screen: ScreenInfo(width: 3440, height: 1440),
            scene: [SceneApp(appKey: "pid:1", pid: 1, bundleID: "com.x", name: "A",
                             status: .synced, capturedAt: Date(timeIntervalSince1970: 999),
                             entityCount: 6, children: scene)],
            index: SpatialIndex.build(from: fixture(), gridSize: 0),
            frontmostApp: "pid:1",
            status: .ok
        )
        let data = try JSONEncoder.gvgl.encode(frame)
        let decoded = try JSONDecoder.gvgl.decode(GVGLFrame.self, from: data)
        XCTAssertEqual(decoded.version, 7)
        XCTAssertEqual(decoded.frontmostApp, "pid:1")
        XCTAssertEqual(decoded.scene.first?.children.map(\.id), ["pid:1:mb", "pid:1:0"])
        XCTAssertEqual(decoded.scene.first?.children[1].children?.map(\.id), ["pid:1:0-0", "pid:1:0-1"])
        XCTAssertEqual(decoded.allEntities.count, 6)
    }
}
