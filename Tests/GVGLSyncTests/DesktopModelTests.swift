import XCTest
@testable import GVGLSync
@testable import GVGLCore

final class DesktopModelTests: XCTestCase {
    private let screen = ScreenInfo(width: 3440, height: 1440)

    private func output(_ entityID: String) -> PipelineOutput {
        let e = Entity(
            id: entityID, role: "AXWindow", title: nil, detail: nil, identifier: nil,
            enabled: true, actions: [],
            axParentID: nil, entityParentID: nil, windowID: entityID,
            appID: "pid:1", pid: 1,
            geometry: Geometry(screen: .unit, window: .unit)
        )
        return PipelineOutput(
            entities: [e],
            relations: [Relation(type: .inside, from: entityID, to: entityID)],
            index: SpatialIndex.build(from: [e])
        )
    }

    private func meta(_ key: String, _ pid: Int32, _ name: String?) -> AppSnapshot {
        AppSnapshot(appKey: key, pid: pid, bundleID: nil, name: name, status: .warming, capturedAt: Date(), entityCount: 0)
    }

    func testUpsertAggregatesAndBumpsVersion() {
        let model = DesktopModel()
        model.upsert(appKey: "pid:1", output: output("e1"), meta: meta("pid:1", 1, "A"))
        model.upsert(appKey: "pid:2", output: output("e2"), meta: meta("pid:2", 2, "B"))

        let frame = model.frame(screen: screen)
        XCTAssertEqual(frame.allEntities.map(\.id), ["e1", "e2"])
        XCTAssertEqual(frame.scene.count, 2)
        XCTAssertEqual(frame.version, 2)
        XCTAssertEqual(frame.status, .ok)
        XCTAssertEqual(frame.allEntities[0].pid, 1)
    }

    func testFilterApp() {
        let model = DesktopModel()
        model.upsert(appKey: "pid:1", output: output("e1"), meta: meta("pid:1", 1, "A"))
        model.upsert(appKey: "pid:2", output: output("e2"), meta: meta("pid:2", 2, "B"))

        let frame = model.frame(screen: screen, filterApp: "pid:2")
        XCTAssertEqual(frame.allEntities.map(\.id), ["e2"])
        XCTAssertEqual(frame.scene.map(\.appKey), ["pid:2"])
    }

    func testStatusTransitions() {
        let model = DesktopModel()
        XCTAssertEqual(model.frame(screen: screen).status, .unavailable)

        // setStatus creates an observable placeholder state.
        model.setStatus(appKey: "pid:1", pid: 1, .warming)
        XCTAssertEqual(model.frame(screen: screen).status, .warming)

        model.upsert(appKey: "pid:1", output: output("e1"), meta: meta("pid:1", 1, "A"), truncated: true)
        XCTAssertEqual(model.frame(screen: screen).status, .partial)

        model.upsert(appKey: "pid:1", output: output("e1"), meta: meta("pid:1", 1, "A"))
        XCTAssertEqual(model.frame(screen: screen).status, .ok)
    }

    func testSetStatusAndRemove() {
        let model = DesktopModel()
        model.upsert(appKey: "pid:1", output: output("e1"), meta: meta("pid:1", 1, "A"))
        model.setStatus(appKey: "pid:1", pid: 1, .permissionDenied)
        XCTAssertEqual(model.meta(appKey: "pid:1")?.status, .permissionDenied)
        XCTAssertEqual(model.frame(screen: screen).status, .permissionDenied)

        XCTAssertTrue(model.removeApp(appKey: "pid:1"))
        XCTAssertNil(model.meta(appKey: "pid:1"))
        XCTAssertEqual(model.frame(screen: screen).status, .unavailable)
    }

    func testVersionMonotonic() {
        let model = DesktopModel()
        let v0 = model.version
        model.upsert(appKey: "pid:1", output: output("e1"), meta: meta("pid:1", 1, "A"))
        model.upsert(appKey: "pid:1", output: output("e1"), meta: meta("pid:1", 1, "A"))
        model.removeApp(appKey: "pid:1")
        XCTAssertGreaterThan(model.version, v0 + 2)
    }

    func testWaitForVersionReturnsOnBump() {
        let model = DesktopModel()
        let expectation = expectation(description: "wait returns")
        DispatchQueue.global().async {
            let v = model.waitForVersion(after: 0, timeout: 3)
            XCTAssertNotNil(v)
            expectation.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        model.upsert(appKey: "pid:1", output: output("e1"), meta: meta("pid:1", 1, "A"))
        wait(for: [expectation], timeout: 3)
    }

    func testWaitForVersionTimesOut() {
        let model = DesktopModel()
        let start = Date()
        let v = model.waitForVersion(after: model.version, timeout: 0.3)
        XCTAssertNil(v, "no bump → timeout returns nil")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25)
    }

    func testChangedAppsReportsDeltas() {
        let model = DesktopModel()
        model.upsert(appKey: "pid:1", output: output("e1"), meta: meta("pid:1", 1, "A"))
        let v1 = model.version
        model.upsert(appKey: "pid:2", output: output("e2"), meta: meta("pid:2", 2, "B"))
        model.setStatus(appKey: "pid:2", pid: 2, .permissionDenied)
        let v3 = model.version

        XCTAssertEqual(model.changedApps(after: v1), ["pid:2"])
        XCTAssertEqual(model.changedApps(after: v3), [])
        XCTAssertTrue(model.changedApps(after: 0).contains("pid:1"))
        XCTAssertTrue(model.changedApps(after: 0).contains("pid:2"))
        XCTAssertEqual(model.changedApps(after: 0).count, 2) // pid:2 twice → deduped
    }

    func testFrameResultWithSince() {
        let model = DesktopModel()
        model.upsert(appKey: "pid:1", output: output("e1"), meta: meta("pid:1", 1, "A"))
        let v1 = model.version
        model.upsert(appKey: "pid:2", output: output("e2"), meta: meta("pid:2", 2, "B"))

        let r = model.frameResult(screen: screen, since: v1)
        XCTAssertEqual(r.frame.version, model.version)
        XCTAssertEqual(r.changedApps, ["pid:2"])
    }

    // MARK: - V3 frontmost app

    func testFrontmostAppFlowsIntoFrame() {
        let model = DesktopModel()
        model.upsert(appKey: "pid:1", output: output("e1"), meta: meta("pid:1", 1, "A"))
        XCTAssertNil(model.frame(screen: screen).frontmostApp)

        let v = model.version
        model.setFrontmost(appKey: "pid:1")
        XCTAssertGreaterThan(model.version, v, "frontmost change bumps the version")
        XCTAssertEqual(model.frame(screen: screen).frontmostApp, "pid:1")

        // Same value again → no version churn.
        let v2 = model.version
        model.setFrontmost(appKey: "pid:1")
        XCTAssertEqual(model.version, v2)
    }

    // MARK: - V4 scene depth limiting

    private func nestedOutput() -> PipelineOutput {
        func e(_ id: String, _ role: String, _ parent: String?) -> Entity {
            Entity(
                id: id, role: role, title: nil, detail: nil, identifier: nil,
                enabled: true, actions: [],
                axParentID: nil, entityParentID: parent, windowID: "w1",
                appID: "pid:1", pid: 1,
                geometry: Geometry(screen: .unit, window: .unit)
            )
        }
        let entities = [
            e("w1", "AXWindow", nil),
            e("c1", "AXToolbar", "w1"),
            e("g1", "AXButton", "c1"),
        ]
        return PipelineOutput(entities: entities, relations: [], index: SpatialIndex.build(from: entities))
    }

    func testFrameDepthPruning() {
        let model = DesktopModel()
        model.upsert(appKey: "pid:1", output: nestedOutput(), meta: meta("pid:1", 1, "A"))

        let full = model.frame(screen: screen)
        XCTAssertEqual(full.allEntities.count, 3)
        XCTAssertEqual(full.scene.first?.children.first?.children?.first?.id, "c1")

        let shallow = model.frame(screen: screen, depth: 1)
        XCTAssertEqual(shallow.allEntities.count, 1, "depth=1 delivers roots only")
        let root = shallow.scene.first?.children.first
        XCTAssertEqual(root?.id, "w1")
        XCTAssertNil(root?.children)
        XCTAssertEqual(root?.prunedChildCount, 1)

        // entityCount reports the full model, not the pruned delivery.
        XCTAssertEqual(shallow.scene.first?.entityCount, 3)
        // The depth variants are cached independently (no cross-talk).
        XCTAssertEqual(model.frame(screen: screen).allEntities.count, 3)
        XCTAssertEqual(model.frame(screen: screen, depth: 2).allEntities.count, 2)
    }
}
