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

    /// `listen()` backlog is deliberately small (16), so opening many
    /// connections back-to-back can transiently exceed it. Retry briefly: the
    /// accept loop drains it, and a load test that dies on EAGAIN would report
    /// a flaky server instead of the property under test.
    private func clientSocketRetrying(attempts: Int = 200) -> Int32 {
        for _ in 0..<attempts {
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
            if rc == 0 { return fd }
            close(fd)
            usleep(10_000)
        }
        XCTFail("could not connect after \(attempts) attempts")
        return -1
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

    /// A cursor exactly at the current version is the only true no-op.
    func testGetFrameSinceNoChange() {
        let fd = clientSocket()
        sendLine(fd, #"{"method":"get_frame","since":999}"#)
        let line = readLine(fd)
        close(fd)
        // Model is empty (version 0) and the cursor is ahead of it — a
        // desynced client, not an idle one. It must be told to refresh.
        XCTAssertTrue(line.contains(#""requires_full_refresh":true"#), "got: \(line)")
    }

    func testGetFrameSinceCurrentVersionIsNoChange() {
        let current = model.version
        let fd = clientSocket()
        sendLine(fd, #"{"method":"get_frame","since":\#(current)}"#)
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
        XCTAssertTrue(line.contains(#""requires_full_refresh":false"#), "got: \(line)")
    }

    func testGetFrameSinceExpiredCursorRequestsFullRefresh() {
        for i in 0...512 {
            let appKey = "pid:\(i)"
            model.upsert(
                appKey: appKey,
                output: PipelineOutput(entities: [makeEntity("e\(i)")], relations: [], index: SpatialIndex()),
                meta: meta(appKey, Int32(i))
            )
        }

        let fd = clientSocket()
        sendLine(fd, #"{"method":"get_frame","since":0}"#)
        let line = readLine(fd)
        close(fd)
        XCTAssertTrue(line.contains(#""event":"changed""#), "got: \(line)")
        XCTAssertTrue(line.contains(#""requires_full_refresh":true"#), "got: \(line)")
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

    /// A cursor from a dead daemon incarnation (ahead of the model) must not
    /// wedge the push loop: it is clamped forward to now, flagged as needing
    /// a full refresh, and the next bump is still delivered.
    func testSubscribeWithFutureCursorIsClampedAndFlagged() {
        let model = self.model
        model.upsert(appKey: "pid:1", output: PipelineOutput(entities: [makeEntity("e1")], relations: [], index: SpatialIndex()), meta: meta("pid:1", 1))
        let current = model.version

        let fd = clientSocket()
        sendLine(fd, #"{"method":"subscribe","since":\#(current + 5000)}"#)
        let ack = readLine(fd)
        XCTAssertTrue(ack.contains(#""event":"subscribed""#), "got: \(ack)")
        XCTAssertTrue(ack.contains(#""version":\#(current)"#), "acked version must be current: \(ack)")
        XCTAssertTrue(ack.contains(#""requires_full_refresh":true"#), "got: \(ack)")

        // Without clamping this bump would never wake the loop (the cursor is
        // already ahead of the new version), so the client would hang silent.
        model.upsert(appKey: "pid:2", output: PipelineOutput(entities: [makeEntity("e2")], relations: [], index: SpatialIndex()), meta: meta("pid:2", 2))
        let event = readLine(fd)
        XCTAssertTrue(event.contains(#""event":"frame"#), "got: \(event)")
        XCTAssertTrue(event.contains("pid:2"), "got: \(event)")
        close(fd)
    }

    /// The acked version and the push cursor are one atomic read, so a client
    /// that resumes from the acked version never misses a bump.
    func testSubscribeAckVersionIsCurrentAndNoRefreshWhenInSync() {
        let model = self.model
        model.upsert(appKey: "pid:1", output: PipelineOutput(entities: [makeEntity("e1")], relations: [], index: SpatialIndex()), meta: meta("pid:1", 1))
        let current = model.version

        let fd = clientSocket()
        sendLine(fd, #"{"method":"subscribe","since":\#(current)}"#)
        let ack = readLine(fd)
        XCTAssertTrue(ack.contains(#""version":\#(current)"#), "got: \(ack)")
        XCTAssertTrue(ack.contains(#""requires_full_refresh":false"#), "got: \(ack)")
        close(fd)
    }

    /// Long-lived subscriptions must not be able to starve the server. The
    /// push loop used to run on the same concurrent queue that accepts and
    /// serves requests, so every parked subscriber burned one of GCD's ~64
    /// worker threads; past that the daemon silently stopped answering
    /// anything (measured live: wedged at 63 connections, no error, no log).
    /// The daemon is alive, so only a real request proves the property.
    func testManyConcurrentSubscriptionsDoNotStarveTheServer() {
        let subscribers = (0..<80).map { _ in clientSocketRetrying() }
        defer { subscribers.forEach { close($0) } }
        for fd in subscribers {
            sendLine(fd, #"{"method":"subscribe"}"#)
            XCTAssertTrue(readLine(fd).contains(#""event":"subscribed""#))
        }

        // With every subscription parked, a fresh request must still be served.
        let probe = clientSocketRetrying()
        sendLine(probe, #"{"method":"get_status"}"#)
        let line = readLine(probe, timeout: 10)
        close(probe)
        XCTAssertTrue(line.contains(#""monitoredApps""#), "server stopped answering under load: got: \(line)")
    }

    /// Past the cap the daemon must refuse loudly rather than accept a
    /// subscription it has no thread to run.
    func testSubscribeIsRefusedPastTheCap() {
        let held = (0..<256).map { _ in clientSocketRetrying() }
        var lastAck = ""
        for fd in held {
            sendLine(fd, #"{"method":"subscribe"}"#)
            lastAck = readLine(fd, timeout: 10)
        }
        defer { held.forEach { close($0) } }

        let fd = clientSocketRetrying()
        sendLine(fd, #"{"method":"subscribe"}"#)
        let refused = readLine(fd, timeout: 10)
        close(fd)
        XCTAssertTrue(refused.contains(#""code":"too_many_subscriptions""#),
                      "expected an explicit refusal, got: \(refused) (last ack: \(lastAck))")
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

    /// V5.1 regression: masked-out churn must not disable dead-client
    /// reaping. 12 silently-skipped versions write a ping so a dead masked
    /// client still gets EPIPE'd; matching bumps still push frame events.
    func testMaskedSubscriptionStillPingsUnderChurn() {
        let fd = clientSocket()
        sendLine(fd, #"{"method":"subscribe","regions":["d1q2"]}"#)
        let ack = readLine(fd)
        XCTAssertTrue(ack.contains(#""event":"subscribed""#), "got: \(ack)")

        func entity(_ id: String, rect: NormRect) -> Entity {
            Entity(
                id: id, role: "AXWindow", title: nil, detail: nil, identifier: nil,
                enabled: true, actions: [],
                axParentID: nil, entityParentID: nil, windowID: id,
                appID: "pid:9", pid: 9, appName: nil, displayID: 1,
                geometry: Geometry(screen: rect, window: .unit, display: rect)
            )
        }
        // 12 disjoint (d1q3) bumps, burst-style (waitForVersion may return
        // them as one wake-up — the ping threshold counts versions).
        for i in 0..<12 {
            model.upsert(
                appKey: "pid:9",
                output: PipelineOutput(entities: [entity("far\(i)", rect: NormRect(x: 0.1, y: 0.7, w: 0.1, h: 0.1))],
                                       relations: [], index: SpatialIndex()),
                meta: meta("pid:9", 9)
            )
        }
        let ping = readLine(fd, timeout: 3)
        XCTAssertTrue(ping.contains(#""event":"ping""#),
                      "dead-reap ping must fire under masked churn, got: \(ping)")

        // Matching-region bump: frame event still arrives on the same fd.
        model.upsert(
            appKey: "pid:1",
            output: PipelineOutput(entities: [entity("near", rect: NormRect(x: 0.6, y: 0.2, w: 0.1, h: 0.1))],
                                   relations: [], index: SpatialIndex()),
            meta: meta("pid:1", 1)
        )
        let event = readLine(fd, timeout: 3)
        XCTAssertTrue(event.contains(#""event":"frame""#), "got: \(event)")
        // Close LAST: any further model bump would make the loop write to the
        // closed fd (SIGPIPE in the test process — the daemon ignores it).
        close(fd)
    }
}
