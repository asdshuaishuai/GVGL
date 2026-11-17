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
                     output: PipelineOutput(entities: [makeEntity("e1")]),
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
        // Lock state is part of the wire contract: a locked Mac serves empty
        // AX trees, and "entityCount 0" must stay distinguishable from
        // "empty desktop" (the whole reason this field exists).
        if let raw = try? client.getStatus(), let locked = raw["screenLocked"] {
            XCTAssertEqual(locked as? Bool, typed.screenLocked)
        } else {
            XCTFail("screenLocked missing from get_status payload")
        }
    }

    func testGetFrameSinceRoundtrip() throws {
        model.upsert(appKey: "pid:1",
                     output: PipelineOutput(entities: [makeEntity("e1")]),
                     meta: AppSnapshot(appKey: "pid:1", pid: 1, bundleID: nil, name: "A", status: .synced, capturedAt: Date(), entityCount: 1))
        let client = GVGLClient(socketPath: socketPath, timeout: 5)
        _ = try client.getFrame()
        let v = model.version

        let (frame, apps, full1) = try client.getFrameSince(v)
        XCTAssertNil(frame, "no change after version → no_change")
        XCTAssertTrue(apps.isEmpty)
        XCTAssertFalse(full1, "an exact cursor is a genuine no-op")

        model.upsert(appKey: "pid:2",
                     output: PipelineOutput(entities: [makeEntity("e2")]),
                     meta: AppSnapshot(appKey: "pid:2", pid: 2, bundleID: nil, name: "B", status: .synced, capturedAt: Date(), entityCount: 1))
        let (frame2, apps2, full2) = try client.getFrameSince(v)
        XCTAssertNotNil(frame2)
        XCTAssertEqual(frame2?.allEntities.map(\.id), ["e1", "e2"])
        XCTAssertEqual(apps2, ["pid:2"])
        XCTAssertFalse(full2, "a recent cursor is an ordinary incremental pull")
    }

    /// A cursor from a dead daemon incarnation must not be served as a quiet
    /// no-op: the client has to learn it is desynced, or it waits forever on a
    /// view that will never update again.
    func testGetFrameSinceFutureCursorReportsFullRefresh() throws {
        let client = GVGLClient(socketPath: socketPath, timeout: 5)
        let (frame, apps, requiresFullRefresh) = try client.getFrameSince(999_999)
        XCTAssertNotNil(frame, "a desynced client still gets a complete frame")
        XCTAssertTrue(apps.isEmpty, "the skipped mutations cannot be enumerated")
        XCTAssertTrue(requiresFullRefresh, "client must be told to resync wholesale")
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
                     output: PipelineOutput(entities: entities),
                     meta: AppSnapshot(appKey: "pid:1", pid: 1, bundleID: nil, name: "A", status: .synced, capturedAt: Date(), entityCount: 2000))

        let client = GVGLClient(socketPath: socketPath, timeout: 10)
        let frame = try client.getFrame()
        XCTAssertEqual(frame.allEntities.count, 2000)
    }

    /// A malformed request produces an error message that itself contains
    /// quotes (Swift's DecodingError description). Building the error line by
    /// string interpolation made that response invalid JSON — the client then
    /// failed to parse the explanation of its own mistake.
    func testErrorResponseIsValidJSONEvenWithQuotedMessage() throws {
        let text = SocketServer.errorResponse(
            "invalid_request",
            #"malformed JSON: DecodingError.keyNotFound: CodingKeys(stringValue: "method", intValue: nil)"#
        )
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_request")
        XCTAssertTrue((error["message"] as? String)?.contains("method") == true)
    }
}
