import XCTest
@testable import GVGLSync
@testable import GVGLCore

final class SyncEngineTests: XCTestCase {
    private final class MockCapturer: AppCapturing, @unchecked Sendable {
        var snapshotCount = 0
        var windowSnapshotCount = 0
        var error: AXSnapshotError?
        var makeNodes: (Int32) -> [AXNode] = { _ in [] }
        var makeWindowNodes: (Int32, [Int]) -> AXAppSnapshot? = { _, _ in nil }

        func snapshot(pid: Int32, appKey: String) -> AXAppSnapshot {
            snapshotCount += 1
            if let error {
                return AXAppSnapshot(appKey: appKey, pid: pid, nodes: [], visited: 0, truncated: false, error: error, elapsed: 0)
            }
            return AXAppSnapshot(appKey: appKey, pid: pid, nodes: makeNodes(pid), visited: 0, truncated: false, error: nil, elapsed: 0)
        }

        func snapshotWindow(pid: Int32, appKey: String, path: [Int]) -> AXAppSnapshot? {
            windowSnapshotCount += 1
            return makeWindowNodes(pid, path)
        }
    }

    private let screen = ScreenInfo(width: 3440, height: 1440)

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func windowNode(pid: Int32) -> [AXNode] {
        let key = "pid:\(pid)"
        return [
            AXNode(
                id: "\(key):0", role: "AXWindow", title: "w",
                frame: CGRect(x: 0, y: 0, width: 500, height: 400),
                windowID: "\(key):0"
            )
        ]
    }

    func testMonitorCapturesIntoModel() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        capturer.makeNodes = windowNode
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.02)

        engine.monitor(info: AppInfo(appKey: "pid:42", pid: 42, bundleID: "com.x", name: "X"))
        XCTAssertTrue(waitUntil { model.meta(appKey: "pid:42")?.status == .synced })

        let frame = model.frame(screen: screen)
        XCTAssertEqual(frame.allEntities.count, 1)
        XCTAssertEqual(frame.allEntities.first?.role, "AXWindow")
        XCTAssertEqual(capturer.snapshotCount, 1)
    }

    func testDirtyTriggerRecaptures() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        capturer.makeNodes = windowNode
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.02)

        engine.monitor(info: AppInfo(appKey: "pid:42", pid: 42, bundleID: nil, name: "X"))
        XCTAssertTrue(waitUntil { capturer.snapshotCount == 1 })
        Thread.sleep(forTimeInterval: 0.25) // let the minCaptureInterval throttle window pass

        engine.markDirty(pid: 42)
        XCTAssertTrue(waitUntil { capturer.snapshotCount >= 2 })
        XCTAssertGreaterThan(model.version, 0)
    }

    func testDebounceCoalescesBurst() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        capturer.makeNodes = windowNode
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.05)

        engine.monitor(info: AppInfo(appKey: "pid:42", pid: 42, bundleID: nil, name: "X"))
        XCTAssertTrue(waitUntil { capturer.snapshotCount == 1 })
        Thread.sleep(forTimeInterval: 0.25) // let the minCaptureInterval throttle window pass

        // Burst of 5 dirty marks → coalesced into a single flush.
        for _ in 0..<5 { engine.markDirty(pid: 42) }
        XCTAssertTrue(waitUntil { capturer.snapshotCount >= 2 })
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(capturer.snapshotCount, 2, "burst must coalesce into exactly one recapture")
    }

    func testPermissionDeniedStatus() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        capturer.error = .permissionDenied
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.02)

        engine.monitor(info: AppInfo(appKey: "pid:42", pid: 42, bundleID: nil, name: "X"))
        XCTAssertTrue(waitUntil { model.meta(appKey: "pid:42")?.status == .permissionDenied })
        XCTAssertEqual(model.frame(screen: screen).status, .permissionDenied)
    }

    func testUnmonitorRemovesModel() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        capturer.makeNodes = windowNode
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.02)

        engine.monitor(info: AppInfo(appKey: "pid:42", pid: 42, bundleID: nil, name: "X"))
        XCTAssertTrue(waitUntil { capturer.snapshotCount == 1 })

        engine.unmonitor(pid: 42)
        XCTAssertTrue(waitUntil { model.meta(appKey: "pid:42") == nil })
        XCTAssertEqual(model.frame(screen: screen).status, .unavailable)
    }

    func testStabilizationKeepsIDsAcrossRecaptures() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        capturer.makeNodes = { pid in
            let key = "pid:\(pid)"
            let staticText = AXNode(
                id: "\(key):0-0-0", role: "AXStaticText", title: "标签",
                frame: CGRect(x: 100, y: 100, width: 40, height: 16),
                parentID: "\(key):0-0", windowID: "\(key):0"
            )
            let button = AXNode(
                id: "\(key):0-0", role: "AXButton", title: "登录",
                frame: CGRect(x: 100, y: 100, width: 80, height: 40),
                parentID: "\(key):0", windowID: "\(key):0",
                children: [staticText]
            )
            return [
                AXNode(
                    id: "\(key):0", role: "AXWindow", title: "w",
                    frame: CGRect(x: 0, y: 0, width: 500, height: 400),
                    parentID: "\(key):root", windowID: "\(key):0",
                    children: [button]
                )
            ]
        }
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.02)
        engine.monitor(info: AppInfo(appKey: "pid:42", pid: 42, bundleID: nil, name: "X"))
        // Wait for the model, not the snapshot counter: the counter bumps
        // inside snapshot() while pipeline/upsert still run.
        XCTAssertTrue(waitUntil { model.meta(appKey: "pid:42")?.status == .synced })

        let firstIDs = Set(model.frame(screen: screen).allEntities.map(\.id))
        XCTAssertTrue(firstIDs.contains("pid:42:0-0"))

        // Tree shifts: a window-level node appears before the button → button
        // path becomes 0-1; the button itself is identical (same title/position).
        Thread.sleep(forTimeInterval: 0.25) // throttle window
        capturer.makeNodes = { pid in
            let key = "pid:\(pid)"
            let staticText = AXNode(
                id: "\(key):0-1-0", role: "AXStaticText", title: "标签",
                frame: CGRect(x: 100, y: 100, width: 40, height: 16),
                parentID: "\(key):0-1", windowID: "\(key):0"
            )
            let button = AXNode(
                id: "\(key):0-1", role: "AXButton", title: "登录",
                frame: CGRect(x: 100, y: 100, width: 80, height: 40),
                parentID: "\(key):0", windowID: "\(key):0",
                children: [staticText]
            )
            return [
                AXNode(
                    id: "\(key):0", role: "AXWindow", title: "w",
                    frame: CGRect(x: 0, y: 0, width: 500, height: 400),
                    parentID: "\(key):root", windowID: "\(key):0",
                    children: [button]
                )
            ]
        }
        engine.markDirty(pid: 42)
        XCTAssertTrue(waitUntil { capturer.snapshotCount >= 2 })

        let secondIDs = Set(model.frame(screen: screen).allEntities.map(\.id))
        XCTAssertTrue(secondIDs.contains("pid:42:0-0"),
                      "button id must be preserved after tree shift; got \(secondIDs)")
        XCTAssertTrue(secondIDs.contains("pid:42:0-0-0"),
                      "static text id must be preserved after tree shift")
        XCTAssertEqual(firstIDs, secondIDs, "whole frame ids should be stable")
    }

    func testAllowedBundleIDsWhitelist() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.02)
        engine.allowedBundleIDs = ["com.example.allowed"]

        engine.monitor(info: AppInfo(appKey: "pid:1", pid: 1, bundleID: "com.example.blocked", name: "B"))
        engine.monitor(info: AppInfo(appKey: "pid:2", pid: 2, bundleID: "com.example.allowed", name: "A"))
        // Apps without a bundle id can't match any whitelist entry → blocked.
        engine.monitor(info: AppInfo(appKey: "pid:3", pid: 3, bundleID: nil, name: "N"))
        XCTAssertTrue(waitUntil { capturer.snapshotCount == 1 })

        XCTAssertNil(model.meta(appKey: "pid:1"), "blocked bundle must not be monitored")
        XCTAssertNotNil(model.meta(appKey: "pid:2"))
        XCTAssertNil(model.meta(appKey: "pid:3"), "nil bundle id must not slip through the whitelist")
    }

    func testDisplaysDidReconfigureMarksAllAppsDirty() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        capturer.makeNodes = windowNode
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.02)

        engine.monitor(info: AppInfo(appKey: "pid:1", pid: 1, bundleID: nil, name: "A"))
        engine.monitor(info: AppInfo(appKey: "pid:2", pid: 2, bundleID: nil, name: "B"))
        XCTAssertTrue(waitUntil { capturer.snapshotCount == 2 })
        Thread.sleep(forTimeInterval: 0.25) // minCaptureInterval throttle window

        engine.displaysDidReconfigure()
        XCTAssertTrue(waitUntil { capturer.snapshotCount >= 4 },
                      "reconfiguration must schedule a full refresh, got \(capturer.snapshotCount)")
    }

    func testScreenRefreshViaReader() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.02)
        let newScreen = ScreenInfo(width: 1000, height: 800, scaleFactor: 2)
        engine.screenReader = { newScreen }

        engine.refreshScreen()
        XCTAssertEqual(engine.screen, newScreen)
    }

    // MARK: - Reconciler batch selection (V3 speedup)

    private func appInfos(_ count: Int) -> [AppInfo] {
        (1...count).map { AppInfo(appKey: "pid:\($0)", pid: Int32($0), bundleID: nil, name: "A\($0)") }
    }

    func testReconcileBatchPrefersStalestApps() {
        let now = Date()
        let infos = appInfos(3)
        let lastCaptured: [String: Date] = [
            "pid:1": now.addingTimeInterval(-10), // stalest
            "pid:2": now.addingTimeInterval(-5),
            "pid:3": now.addingTimeInterval(-1),
        ]
        let batch = SyncEngine.selectReconcileBatch(
            due: infos, lastCaptured: lastCaptured,
            totalMonitored: 3, interval: 3, sweepTarget: 15, minBatch: 3
        )
        XCTAssertEqual(batch.map(\.appKey), ["pid:1", "pid:2", "pid:3"])
        // Never-captured apps (distantPast) sort ahead of everything.
        let batch2 = SyncEngine.selectReconcileBatch(
            due: infos, lastCaptured: ["pid:1": now],
            totalMonitored: 3, interval: 3, sweepTarget: 15, minBatch: 1
        )
        XCTAssertEqual(batch2.first?.appKey, "pid:2")
    }

    func testReconcileBatchAdaptsToMonitoredCount() {
        // 80 monitored apps, 3s tick, 15s sweep target → 5 ticks → 16/tick.
        let batch = SyncEngine.selectReconcileBatch(
            due: appInfos(80), lastCaptured: [:],
            totalMonitored: 80, interval: 3, sweepTarget: 15, minBatch: 3
        )
        XCTAssertEqual(batch.count, 16)
        // Few apps → the floor (minBatch) governs: ceil(4/5)=1 → max(3,1)=3.
        let small = SyncEngine.selectReconcileBatch(
            due: appInfos(4), lastCaptured: [:],
            totalMonitored: 4, interval: 3, sweepTarget: 15, minBatch: 3
        )
        XCTAssertEqual(small.count, 3)
        // …but the batch never exceeds the number of due apps.
        let capped = SyncEngine.selectReconcileBatch(
            due: appInfos(2), lastCaptured: [:],
            totalMonitored: 80, interval: 3, sweepTarget: 15, minBatch: 3
        )
        XCTAssertEqual(capped.count, 2)
        // Tiny sweep target clamps to one tick per sweep.
        let aggressive = SyncEngine.selectReconcileBatch(
            due: appInfos(10), lastCaptured: [:],
            totalMonitored: 10, interval: 3, sweepTarget: 2, minBatch: 3
        )
        XCTAssertEqual(aggressive.count, 10)
    }

    // MARK: - Per-window subtree recapture (V1.6-2)

    private func twoWindowNodes(pid: Int32, bTitle: String) -> [AXNode] {
        let key = "pid:\(pid)"
        let winA = AXNode(
            id: "\(key):0", role: "AXWindow", title: "A",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            parentID: "\(key):root", windowID: "\(key):0"
        )
        let btnB = AXNode(
            id: "\(key):1-0", role: "AXButton", title: bTitle,
            frame: CGRect(x: 50, y: 50, width: 80, height: 30),
            parentID: "\(key):1", windowID: "\(key):1"
        )
        let winB = AXNode(
            id: "\(key):1", role: "AXWindow", title: "B",
            frame: CGRect(x: 500, y: 0, width: 400, height: 300),
            parentID: "\(key):root", windowID: "\(key):1",
            children: [btnB]
        )
        return [AXNode(
            id: "\(key):root", role: nil, frame: nil,
            parentID: nil, windowID: nil, children: [winA, winB]
        )]
    }

    func testWindowSubtreeRecaptureOnlyUpdatesTargetWindow() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        capturer.makeNodes = { [self] pid in twoWindowNodes(pid: pid, bTitle: "旧标题") }
        capturer.makeWindowNodes = { [self] pid, path in
            XCTAssertEqual(path, [1])
            let key = "pid:\(pid)"
            let btnB = AXNode(
                id: "\(key):1-0", role: "AXButton", title: "新标题",
                frame: CGRect(x: 50, y: 50, width: 80, height: 30),
                parentID: "\(key):1", windowID: "\(key):1"
            )
            return AXAppSnapshot(
                appKey: key, pid: pid,
                nodes: [AXNode(
                    id: "\(key):1", role: "AXWindow", title: "B",
                    frame: CGRect(x: 600, y: 0, width: 400, height: 300),
                    parentID: "\(key):root", windowID: "\(key):1",
                    children: [btnB]
                )],
                visited: 0, truncated: false, error: nil, elapsed: 0
            )
        }
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.02)
        engine.monitor(info: AppInfo(appKey: "pid:42", pid: 42, bundleID: nil, name: "X"))
        // Wait for the model, not the snapshot counter (counter bumps inside
        // snapshot() while pipeline/upsert still run).
        XCTAssertTrue(waitUntil { model.meta(appKey: "pid:42")?.status == .synced })

        let before = model.frame(screen: screen)
        guard let winA0 = before.allEntities.first(where: { $0.id == "pid:42:0" }),
              let winB0 = before.allEntities.first(where: { $0.id == "pid:42:1" }) else {
            return XCTFail("fixture windows missing")
        }
        Thread.sleep(forTimeInterval: 0.25) // throttle window

        // Window B moved (its old rect is 500,0 → subtree capture path [1]).
        engine.markWindowDirty(pid: 42, rect: CGRect(x: 600, y: 0, width: 400, height: 300))
        XCTAssertTrue(waitUntil { capturer.windowSnapshotCount >= 1 })
        XCTAssertTrue(waitUntil { model.version > before.version })

        let after = model.frame(screen: screen)
        guard let winA1 = after.allEntities.first(where: { $0.id == "pid:42:0" }),
              let winB1 = after.allEntities.first(where: { $0.id == "pid:42:1" }) else {
            return XCTFail("windows missing after recapture")
        }

        // Window A: byte-identical (same title, same geometry).
        XCTAssertEqual(winA1.title, winA0.title)
        XCTAssertEqual(winA1.geometry, winA0.geometry)
        // Window B: rect updated, button title updated.
        XCTAssertEqual(winB1.geometry.screen.x, 600.0 / 3440.0, accuracy: 1e-6)
        let btn = after.allEntities.first(where: { $0.id == "pid:42:1-0" })
        XCTAssertEqual(btn?.title, "新标题")
        // Full capture not re-run for the subtree path.
        XCTAssertEqual(capturer.snapshotCount, 1)
    }

    func testWindowRecaptureFallsBackToFullCapture() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        capturer.makeNodes = { [self] pid in twoWindowNodes(pid: pid, bTitle: "x") }
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.02)
        engine.monitor(info: AppInfo(appKey: "pid:42", pid: 42, bundleID: nil, name: "X"))
        XCTAssertTrue(waitUntil { capturer.snapshotCount == 1 })
        Thread.sleep(forTimeInterval: 0.25)

        // snapshotWindow not implemented (nil) → falls back to full capture.
        engine.markWindowDirty(pid: 42, rect: CGRect(x: 500, y: 0, width: 400, height: 300))
        XCTAssertTrue(waitUntil { capturer.snapshotCount >= 2 })
        XCTAssertEqual(capturer.windowSnapshotCount, 1, "subtree attempt made, then fallback")
    }

    func testWindowRectMismatchCapturesNothing() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        capturer.makeNodes = { [self] pid in twoWindowNodes(pid: pid, bTitle: "x") }
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.02)
        engine.monitor(info: AppInfo(appKey: "pid:42", pid: 42, bundleID: nil, name: "X"))
        XCTAssertTrue(waitUntil { capturer.snapshotCount == 1 })
        Thread.sleep(forTimeInterval: 0.25)
        let versionBefore = model.version

        // Rect far from every known window → no window matched → no capture.
        engine.markWindowDirty(pid: 42, rect: CGRect(x: 3000, y: 1000, width: 100, height: 100))
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(capturer.windowSnapshotCount, 0)
        XCTAssertEqual(capturer.snapshotCount, 1)
        XCTAssertEqual(model.version, versionBefore)
    }

    /// Window with a nested AXWindow (sheet / Electron inner window): the
    /// subtree recapture re-produces the sheet's entities too. The keep-filter
    /// used to compare only the top-level windowID, so the sheet's previous
    /// entities survived AND the fresh copy was added — the same path id twice
    /// (live-audit duplicates on Electron apps).
    private func windowWithSheetNodes(pid: Int32, buttonTitle: String) -> [AXNode] {
        let key = "pid:\(pid)"
        let sheetButton = AXNode(
            id: "\(key):0-1-0", role: "AXButton", title: buttonTitle,
            frame: CGRect(x: 20, y: 20, width: 60, height: 24),
            parentID: "\(key):0-1", windowID: "\(key):0-1"
        )
        let sheet = AXNode(
            id: "\(key):0-1", role: "AXWindow", title: "Sheet",
            frame: CGRect(x: 10, y: 10, width: 200, height: 150),
            parentID: "\(key):0", windowID: "\(key):0-1",
            children: [sheetButton]
        )
        let win = AXNode(
            id: "\(key):0", role: "AXWindow", title: "Main",
            frame: CGRect(x: 0, y: 0, width: 500, height: 400),
            parentID: "\(key):root", windowID: "\(key):0",
            children: [sheet]
        )
        return [AXNode(id: "\(key):root", role: nil, frame: nil,
                       parentID: nil, windowID: nil, children: [win])]
    }

    func testWindowRecaptureWithNestedSheetDoesNotDuplicate() {
        let model = DesktopModel()
        let capturer = MockCapturer()
        capturer.makeNodes = { [self] pid in windowWithSheetNodes(pid: pid, buttonTitle: "旧") }
        capturer.makeWindowNodes = { [self] pid, path in
            XCTAssertEqual(path, [0])
            let key = "pid:\(pid)"
            return AXAppSnapshot(
                appKey: key, pid: pid,
                nodes: windowWithSheetNodes(pid: pid, buttonTitle: "新").compactMap { node in
                    // Subtree capture roots at the window itself (no app root).
                    node.children.first
                },
                visited: 0, truncated: false, error: nil, elapsed: 0
            )
        }
        let engine = SyncEngine(model: model, capturer: capturer, screen: screen, debounceInterval: 0.02)
        engine.monitor(info: AppInfo(appKey: "pid:42", pid: 42, bundleID: nil, name: "X"))
        XCTAssertTrue(waitUntil { model.meta(appKey: "pid:42")?.status == .synced })
        Thread.sleep(forTimeInterval: 0.25) // throttle window

        let before = model.frame(screen: screen)
        XCTAssertEqual(before.allEntities.count, 3, "window + sheet + sheet button")
        engine.markWindowDirty(pid: 42, rect: CGRect(x: 0, y: 0, width: 500, height: 400))
        XCTAssertTrue(waitUntil { capturer.windowSnapshotCount >= 1 })
        XCTAssertTrue(waitUntil { model.version > before.version })

        let after = model.frame(screen: screen)
        let all = after.allEntities
        XCTAssertEqual(all.count, 3, "sheet entities must be replaced, not duplicated")
        for id in ["pid:42:0", "pid:42:0-1", "pid:42:0-1-0"] {
            XCTAssertEqual(all.filter { $0.id == id }.count, 1, "\(id) must appear exactly once")
        }
        XCTAssertEqual(all.first { $0.id == "pid:42:0-1-0" }?.title, "新",
                       "fresh subtree content wins over the stale copy")
    }
}
