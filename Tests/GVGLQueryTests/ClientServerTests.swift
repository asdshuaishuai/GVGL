import XCTest
@testable import GVGLQuery
@testable import GVGLServer
@testable import GVGLSync
@testable import GVGLCore
import Darwin

/// Deterministic wire test: real SocketServer + real GVGLClient.
final class ClientServerTests: XCTestCase {
    private let screen = ScreenInfo(width: 3440, height: 1440)

    private final class MockCapturer: AppCapturing, @unchecked Sendable {
        func snapshot(pid: Int32, appKey: String) -> AXAppSnapshot {
            AXAppSnapshot(appKey: appKey, pid: pid, nodes: [], visited: 0, truncated: false, error: nil, elapsed: 0)
        }
    }

    private func makeEntity(_ id: String) -> Entity {
        Entity(
            id: id, role: "AXWindow", title: nil, detail: nil, identifier: nil,
            enabled: true, actions: [],
            axParentID: nil, entityParentID: nil, windowID: id,
            appID: "pid:1", pid: 1,
            geometry: Geometry(screen: .unit, window: .unit)
        )
    }

    private var socketPath: String!
    private var model: DesktopModel!

    override func setUp() {
        super.setUp()
        socketPath = NSTemporaryDirectory() + "gvgl-client-\(UUID().uuidString).sock"
        model = DesktopModel()
        let engine = SyncEngine(model: model, capturer: MockCapturer(), screen: screen)
        let server = SocketServer(socketPath: socketPath, model: model, engine: engine)
        try! server.start()
        self.server = server
    }

    override func tearDown() {
        server?.stop()
        unlink(socketPath)
        super.tearDown()
    }

    private var server: SocketServer?

    func testGetFrameRoundtrip() throws {
        model.upsert(appKey: "pid:1",
                     output: PipelineOutput(entities: [makeEntity("e1")], relations: [], index: SpatialIndex()),
                     meta: AppSnapshot(appKey: "pid:1", pid: 1, bundleID: nil, name: "A", status: .synced, capturedAt: Date(), entityCount: 1))

        let client = GVGLClient(socketPath: socketPath, timeout: 5)
        let frame = try client.getFrame()
        XCTAssertEqual(frame.allEntities.map(\.id), ["e1"])
        XCTAssertEqual(frame.version, model.version)
        // Scene shape: e1 is a root of the pid:1 app node.
        XCTAssertEqual(frame.scene.map(\.appKey), ["pid:1"])
        XCTAssertEqual(frame.scene.first?.children.map(\.id), ["e1"])
    }

    func testGetStatusRoundtrip() throws {
        let client = GVGLClient(socketPath: socketPath, timeout: 5)
        let status = try client.getStatus()
        XCTAssertNotNil(status["version"])
    }

    func testGetStatusTypedRoundtrip() throws {
        let client = GVGLClient(socketPath: socketPath, timeout: 5)
        let typed = try client.getStatusTyped()
        XCTAssertEqual(typed.version, model.version)
        XCTAssertGreaterThanOrEqual(typed.monitoredApps, 0)
        XCTAssertTrue(["ok", "warming", "partial", "permissionDenied", "unavailable"].contains(typed.frameStatus))
        XCTAssertEqual(typed.socket, socketPath)
    }

    func testGetFrameSinceRoundtrip() throws {
        model.upsert(appKey: "pid:1",
                     output: PipelineOutput(entities: [makeEntity("e1")], relations: [], index: SpatialIndex()),
                     meta: AppSnapshot(appKey: "pid:1", pid: 1, bundleID: nil, name: "A", status: .synced, capturedAt: Date(), entityCount: 1))
        let client = GVGLClient(socketPath: socketPath, timeout: 5)
        _ = try client.getFrame()
        let v = model.version

        let (frame, apps) = try client.getFrameSince(v)
        XCTAssertNil(frame, "no change after version → no_change")
        XCTAssertTrue(apps.isEmpty)

        model.upsert(appKey: "pid:2",
                     output: PipelineOutput(entities: [makeEntity("e2")], relations: [], index: SpatialIndex()),
                     meta: AppSnapshot(appKey: "pid:2", pid: 2, bundleID: nil, name: "B", status: .synced, capturedAt: Date(), entityCount: 1))
        let (frame2, apps2) = try client.getFrameSince(v)
        XCTAssertNotNil(frame2)
        XCTAssertEqual(frame2?.allEntities.map(\.id), ["e1", "e2"])
        XCTAssertEqual(apps2, ["pid:2"])
    }

    func testLargeFrameRoundtrip() throws {
        // 2000 entities → multi-chunk response must survive readLine.
        let entities = (0..<2000).map { i -> Entity in
            let id = "pid:1:0-\(i)"
            return Entity(
                id: id, role: "AXButton", title: "b\(i)", detail: nil, identifier: nil,
                enabled: true, actions: ["AXPress"],
                axParentID: "pid:1:0", entityParentID: "pid:1:0", windowID: "pid:1:0",
                appID: "pid:1", pid: 1,
                geometry: Geometry(screen: NormRect(x: 0.01, y: 0.01, w: 0.02, h: 0.02),
                                   window: NormRect(x: 0.01, y: 0.01, w: 0.02, h: 0.02))
            )
        }
        model.upsert(appKey: "pid:1",
                     output: PipelineOutput(entities: entities, relations: [], index: SpatialIndex.build(from: entities, gridSize: 0)),
                     meta: AppSnapshot(appKey: "pid:1", pid: 1, bundleID: nil, name: "A", status: .synced, capturedAt: Date(), entityCount: 2000))

        let client = GVGLClient(socketPath: socketPath, timeout: 10)
        let frame = try client.getFrame()
        XCTAssertEqual(frame.allEntities.count, 2000)
    }
}
