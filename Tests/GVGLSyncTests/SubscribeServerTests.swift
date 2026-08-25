import XCTest
@testable import GVGLSync
@testable import GVGLServer
@testable import GVGLCore
import Darwin

/// Wire-level tests for the subscribe push + since incremental pull, using a
/// real Unix Domain Socket and a model mutated directly (no AX involved).
final class SubscribeServerTests: XCTestCase {
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

    private func meta(_ key: String, _ pid: Int32) -> AppSnapshot {
        AppSnapshot(appKey: key, pid: pid, bundleID: nil, name: "A", status: .warming, capturedAt: Date(), entityCount: 0)
    }

    private var socketPath: String!
    private var server: SocketServer!

    override func setUp() {
        super.setUp()
        socketPath = NSTemporaryDirectory() + "gvgl-test-\(UUID().uuidString).sock"
        let model = DesktopModel()
        let engine = SyncEngine(model: model, capturer: MockCapturer(), screen: screen)
        server = SocketServer(socketPath: socketPath, model: model, engine: engine)
        try! server.start()
    }

    override func tearDown() {
        server?.stop()
        unlink(socketPath)
        super.tearDown()
    }

    private var model: DesktopModel { server.model }

    private func clientSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: Int8.self, capacity: 108) { dst in
                strlcpy(dst, socketPath, 108)
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(rc, 0)
        return fd
    }

    private func sendLine(_ fd: Int32, _ line: String) {
        let payload = (line + "\n").data(using: .utf8)!
        payload.withUnsafeBytes { _ = write(fd, $0.baseAddress, payload.count) }
    }

    private func readLine(_ fd: Int32, timeout: TimeInterval = 3) -> String {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var data = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while !data.contains(0x0A) && Date() < deadline {
            var tv = timeval(tv_sec: 0, tv_usec: 200_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                data.append(contentsOf: buffer[0..<n])
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func testGetFrameSinceNoChange() {
        let fd = clientSocket()
        sendLine(fd, #"{"method":"get_frame","since":999}"#)
        let line = readLine(fd)
        close(fd)
        XCTAssertTrue(line.contains(#""event":"no_change""#), "got: \(line)")
    }

    /// V5: get_map returns the coarse desktop map built from the model —
    /// windows front-to-back with display index and quadrant labels.
    func testGetMap() throws {
        let entity = makeEntity("e1")
        model.setFrontmost(appKey: "pid:1")
        model.upsert(
            appKey: "pid:1",
            output: PipelineOutput(entities: [entity], relations: [], index: SpatialIndex()),
            meta: meta("pid:1", 1)
        )
        let fd = clientSocket()
        sendLine(fd, #"{"method":"get_map"}"#)
        let line = readLine(fd)
        close(fd)

        guard let data = line.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = payload["result"] as? [String: Any] else {
            return XCTFail("bad get_map response: \(line)")
        }
        XCTAssertEqual(result["version"] as? Int, Int(model.version))
        XCTAssertNotNil(result["frontmostApp"])
        let displays = result["displays"] as? [[String: Any]] ?? []
        XCTAssertEqual(displays.count, 1, "no display info → synthesized main display")
        XCTAssertEqual(displays[0]["index"] as? Int, 0)
        let windows = result["windows"] as? [[String: Any]] ?? []
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0]["id"] as? String, "e1")
        XCTAssertEqual(windows[0]["region"] as? String, "q4", "unit rect center (0.5,0.5) → q4")
    }

    func testGetFrameSinceChanged() {
        let model = self.model
        model.upsert(appKey: "pid:1", output: PipelineOutput(entities: [makeEntity("e1")], relations: [], index: SpatialIndex()), meta: meta("pid:1", 1))
        let v1 = model.version
        model.upsert(appKey: "pid:2", output: PipelineOutput(entities: [makeEntity("e2")], relations: [], index: SpatialIndex()), meta: meta("pid:2", 2))

        let fd = clientSocket()
        sendLine(fd, #"{"method":"get_frame","since":"# + "\(v1)" + "}")
        let line = readLine(fd)
        close(fd)
        XCTAssertTrue(line.contains(#""event":"changed""#), "got: \(line)")
        XCTAssertTrue(line.contains(#""changed_apps":["pid:2"]"#), "got: \(line)")
    }

    func testSubscribePushesVersionEvents() {
        let fd = clientSocket()
        sendLine(fd, #"{"method":"subscribe"}"#)
        let ack = readLine(fd)
        XCTAssertTrue(ack.contains(#""event":"subscribed""#), "got: \(ack)")

        // Bump the model twice; expect two push events.
        model.upsert(appKey: "pid:1", output: PipelineOutput(entities: [makeEntity("e1")], relations: [], index: SpatialIndex()), meta: meta("pid:1", 1))
        let event1 = readLine(fd)
        XCTAssertTrue(event1.contains(#""event":"frame""#), "got: \(event1)")
        XCTAssertTrue(event1.contains("pid:1"), "got: \(event1)")

        model.upsert(appKey: "pid:2", output: PipelineOutput(entities: [makeEntity("e2")], relations: [], index: SpatialIndex()), meta: meta("pid:2", 2))
        let event2 = readLine(fd)
        XCTAssertTrue(event2.contains(#""event":"frame""#), "got: \(event2)")
        XCTAssertTrue(event2.contains("pid:2"), "got: \(event2)")
        close(fd)
    }

    func testSubscribeSinceSkipsOlderVersions() {
        let model = self.model
        model.upsert(appKey: "pid:1", output: PipelineOutput(entities: [makeEntity("e1")], relations: [], index: SpatialIndex()), meta: meta("pid:1", 1))
        let v1 = model.version

        let fd = clientSocket()
        sendLine(fd, #"{"method":"subscribe","since":"# + "\(v1)" + "}")
        _ = readLine(fd) // ack

        model.upsert(appKey: "pid:2", output: PipelineOutput(entities: [makeEntity("e2")], relations: [], index: SpatialIndex()), meta: meta("pid:2", 2))
        let event = readLine(fd)
        XCTAssertTrue(event.contains("pid:2"), "got: \(event)")
        XCTAssertFalse(event.contains("pid:1"), "pre-since changes must not be reported: \(event)")
        close(fd)
    }

    /// V5.1: region-masked subscription — only bumps touching a masked bucket
    /// are pushed; pushed events carry their changed_regions.
    func testSubscribeRegionsMask() {
        let fd = clientSocket()
        sendLine(fd, #"{"method":"subscribe","regions":["d1q2"]}"#)
        let ack = readLine(fd)
        XCTAssertTrue(ack.contains(#""event":"subscribed""#), "got: \(ack)")

        func entity(_ id: String, rect: NormRect, app: String) -> Entity {
            Entity(
                id: id, role: "AXWindow", title: nil, detail: nil, identifier: nil,
                enabled: true, actions: [],
                axParentID: nil, entityParentID: nil, windowID: id,
                appID: app, pid: 1, appName: nil, displayID: 1,
                geometry: Geometry(screen: rect, window: .unit, display: rect)
            )
        }
        func upsert(_ e: Entity, app: String, pid: Int32) {
            model.upsert(
                appKey: app,
                output: PipelineOutput(entities: [e], relations: [], index: SpatialIndex()),
                meta: meta(app, pid)
            )
        }

        // Change in d1q3 (display 1, bottom-left), different app — masked out,
        // must stay silent: readLine times out with no data.
        upsert(entity("far", rect: NormRect(x: 0.1, y: 0.7, w: 0.1, h: 0.1), app: "pid:9"),
               app: "pid:9", pid: 9)
        let nothing = readLine(fd, timeout: 0.8)
        XCTAssertEqual(nothing, "", "masked-out bump must not be pushed, got: \(nothing)")

        // Change in d1q2 — pushed with changed_regions.
        upsert(entity("near", rect: NormRect(x: 0.6, y: 0.2, w: 0.1, h: 0.1), app: "pid:1"),
               app: "pid:1", pid: 1)
        let event = readLine(fd)
        close(fd)
        XCTAssertTrue(event.contains(#""event":"frame""#), "got: \(event)")
        XCTAssertTrue(event.contains(#""changed_regions":["d1q2"]"#), "got: \(event)")
    }
}
