import XCTest
import GVGLCore
@testable import GVGLAction

/// The relocation path is what keeps an action from landing on the wrong
/// element after the AX tree shifted between capture and click. It must be
/// unique-by-construction: a wrong-but-confident match is how the wrong thing
/// gets pressed.
final class RelocationTests: XCTestCase {
    private let screen = ScreenInfo(width: 3440, height: 1440)

    private func entity(_ id: String, role: String = "AXButton", title: String? = nil,
                        identifier: String? = nil, windowID: String? = "w1",
                        x: Double = 0.1, y: Double = 0.1,
                        w: Double = 0.05, h: Double = 0.05) -> Entity {
        Entity(
            id: id, role: role, title: title, detail: nil, identifier: identifier,
            enabled: true, actions: ["AXPress"],
            axParentID: nil, entityParentID: windowID, windowID: windowID,
            appID: "pid:1", pid: 1,
            geometry: Geometry(screen: NormRect(x: x, y: y, w: w, h: h),
                               window: NormRect(x: x, y: y, w: w, h: h))
        )
    }

    private func frame(_ entities: [Entity]) -> GVGLFrame {
        let scene = SceneTree.build(entities: entities)
        return GVGLFrame(
            frameID: "t", version: 1, createdAt: Date(), syncedAt: Date(),
            screen: screen,
            scene: [SceneApp(appKey: "pid:1", pid: 1, bundleID: nil, name: "A",
                             status: .synced, capturedAt: Date(),
                             entityCount: entities.count, children: scene)],
            index: SpatialIndex.build(from: entities, gridSize: 0),
            status: .ok
        )
    }

    private let executor = ActionExecutor(options: ExecutorOptions(socketPath: "/tmp/unused.sock"))

    func testRelocatesByIdentifierWhenPathShifted() {
        let old = entity("pid:1:0-1", title: "登录", identifier: "btn_login")
        let fresh = frame([entity("pid:1:0-7", title: "登录", identifier: "btn_login")])
        XCTAssertEqual(executor.relocate(entity: old, in: fresh)?.id, "pid:1:0-7")
    }

    func testRelocatesByTitleWhenNoIdentifier() {
        let old = entity("pid:1:0-1", title: "登录")
        let fresh = frame([entity("pid:1:0-9", title: "登录")])
        XCTAssertEqual(executor.relocate(entity: old, in: fresh)?.id, "pid:1:0-9")
    }

    func testRelocateRefusesAmbiguousMatches() {
        let old = entity("pid:1:0-1", title: "登录")
        let fresh = frame([
            entity("pid:1:0-2", title: "登录"),
            entity("pid:1:0-3", title: "登录"),
        ])
        XCTAssertNil(executor.relocate(entity: old, in: fresh),
                     "two identical titles is not an address")
    }

    func testRelocatePrefersSameWindow() {
        let old = entity("pid:1:0-1", title: "登录", windowID: "w1")
        let fresh = frame([
            entity("pid:1:0-2", title: "登录", windowID: "w2"),
            entity("pid:1:0-3", title: "登录", windowID: "w1"),
        ])
        XCTAssertEqual(executor.relocate(entity: old, in: fresh)?.id, "pid:1:0-3")
    }

    func testRelocatesByPositionWhenNoIdentity() {
        let old = entity("pid:1:0-1", title: nil, identifier: nil)
        let near = entity("pid:1:0-2", title: nil, identifier: nil, x: 0.101, y: 0.101)
        let far = entity("pid:1:0-3", title: nil, identifier: nil, x: 0.5, y: 0.5)

        XCTAssertEqual(executor.relocate(entity: old, in: frame([near]))?.id, "pid:1:0-2")
        XCTAssertNil(executor.relocate(entity: old, in: frame([far])),
                     "a position jump beyond tolerance is not the same element")
    }
}
