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
}
