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

    // MARK: - V5.1 region hysteresis & change buckets

    private func windowEntity(id: String, displayRect: NormRect, displayID: Int?) -> Entity {
        Entity(
            id: id, role: "AXWindow", title: nil, detail: nil, identifier: nil,
            enabled: true, actions: [],
            axParentID: nil, entityParentID: nil, windowID: id,
            appID: "pid:1", pid: 1, appName: nil, displayID: displayID,
            geometry: Geometry(screen: displayRect, window: .unit, display: displayRect)
        )
    }

    private func upsert(_ model: DesktopModel, _ e: Entity) {
        model.upsert(
            appKey: "pid:1",
            output: PipelineOutput(entities: [e], relations: [], index: SpatialIndex.build(from: [e])),
            meta: meta("pid:1", 1, "A")
        )
    }

    private func firstRegion(_ model: DesktopModel) -> (Region, Region9) {
        let e = model.frame(screen: screen).allEntities[0]
        return (e.geometry.region, e.geometry.region9)
    }

    /// A window whose display-space center rests within the hysteresis band
    /// of the 0.5 boundary keeps its previous quadrant label; crossing beyond
    /// the band flips it. Nine-grid labels behave the same at 1/3 and 2/3.
    func testRegionHysteresisKeepsLabelWithinBand() {
        let model = DesktopModel()
        // centerX 0.49 (q1, 0.01 from the boundary), centerY 0.30 → q1/centerTop.
        upsert(model, windowEntity(id: "w", displayRect: NormRect(x: 0.39, y: 0.20, w: 0.20, h: 0.20), displayID: 1))
        XCTAssertEqual(firstRegion(model).0, .q1)

        // Cross to centerX 0.505 — 0.005 past the boundary, inside the 0.02
        // band → label stays q1 (rect itself is exact).
        upsert(model, windowEntity(id: "w", displayRect: NormRect(x: 0.405, y: 0.20, w: 0.20, h: 0.20), displayID: 1))
        var e = model.frame(screen: screen).allEntities[0]
        XCTAssertEqual(e.geometry.region, .q1, "within band: sticky label")
        XCTAssertEqual(e.geometry.display.centerX, 0.505, accuracy: 1e-9, "rect stays exact")

        // centerY crosses 1/3 (0.30 → 0.345, 0.0117 past, inside band) →
        // centerTop stays; centerX now well past 0.5 → q2 accepted.
        upsert(model, windowEntity(id: "w", displayRect: NormRect(x: 0.46, y: 0.245, w: 0.20, h: 0.20), displayID: 1))
        e = model.frame(screen: screen).allEntities[0]
        XCTAssertEqual(e.geometry.region, .q2, "0.06 past the boundary: flip accepted")
        XCTAssertEqual(e.geometry.region9, .centerTop, "0.0117 past 1/3: sticky within band")

        // Move well past 2/3 vertically too → full flip.
        upsert(model, windowEntity(id: "w", displayRect: NormRect(x: 0.46, y: 0.60, w: 0.20, h: 0.20), displayID: 1))
        XCTAssertEqual(firstRegion(model).1, .centerBottom)
    }

    /// Display change resets hysteresis: the label reflects the new display
    /// immediately (the old label belongs to another screen's geometry).
    func testRegionHysteresisResetsOnDisplayChange() {
        let model = DesktopModel()
        upsert(model, windowEntity(id: "w", displayRect: NormRect(x: 0.39, y: 0.20, w: 0.20, h: 0.20), displayID: 1))
        XCTAssertEqual(firstRegion(model).0, .q1)
        // Same rect shape but on display 2, center lands at 0.505 → fresh
        // computation, q2 (no stickiness carried across displays).
        upsert(model, windowEntity(id: "w", displayRect: NormRect(x: 0.405, y: 0.20, w: 0.20, h: 0.20), displayID: 2))
        XCTAssertEqual(firstRegion(model).0, .q2)
        XCTAssertEqual(model.frame(screen: screen).allEntities[0].displayID, 2)
    }

    /// Regression (review I2): a 9-grid jump across TWO boundaries in one
    /// capture (left → right column) must compare against the boundary
    /// adjacent to the OLD label. The old "far edge" rule stuck the Left
    /// label to positions just inside the Right column, persistently.
    func testRegionHysteresisMultiBoundaryJump() {
        let model = DesktopModel()
        // Left column: centerX 0.15 → region9 left.
        upsert(model, windowEntity(id: "w", displayRect: NormRect(x: 0.05, y: 0.20, w: 0.20, h: 0.20), displayID: 1))
        XCTAssertEqual(firstRegion(model).1, .leftTop)

        // One capture later the window is at centerX 0.68 — inside the Right
        // column (plain index 2), 0.013 past 2/3. The separating boundary
        // from the old label is 1/3 (crossed by 0.347 ≫ band) → flip,
        // NOT stuck at leftTop.
        upsert(model, windowEntity(id: "w", displayRect: NormRect(x: 0.58, y: 0.20, w: 0.20, h: 0.20), displayID: 1))
        XCTAssertEqual(firstRegion(model).1, .rightTop, "multi-boundary jump must not stick the old label")

        // The pure single-boundary stickiness still holds: back at centerX
        // 0.655 (0.012 past 2/3 from a Right-column state) stays rightTop.
        upsert(model, windowEntity(id: "w", displayRect: NormRect(x: 0.555, y: 0.20, w: 0.20, h: 0.20), displayID: 1))
        XCTAssertEqual(firstRegion(model).1, .rightTop, "single-boundary band still sticky")
    }

    /// Region buckets: added/changed entities bucket at their new position,
    /// removed at their old one; byte-identical upserts touch nothing;
    /// frontmost changes log "sys".
    func testChangedRegionBuckets() {
        let model = DesktopModel()
        let a = windowEntity(id: "a", displayRect: NormRect(x: 0.6, y: 0.2, w: 0.1, h: 0.1), displayID: 1)   // d1q2
        let b = windowEntity(id: "b", displayRect: NormRect(x: 0.1, y: 0.7, w: 0.1, h: 0.1), displayID: 2)   // d2q3
        model.upsert(
            appKey: "pid:1",
            output: PipelineOutput(entities: [a, b], relations: [], index: SpatialIndex()),
            meta: meta("pid:1", 1, "A")
        )
        XCTAssertEqual(model.changedRegions(after: 0), ["d1q2", "d2q3"])

        let v1 = model.version
        model.upsert(
            appKey: "pid:1",
            output: PipelineOutput(entities: [a, b], relations: [], index: SpatialIndex()),
            meta: meta("pid:1", 1, "A")
        )
        XCTAssertEqual(model.changedRegions(after: v1), [], "byte-identical upsert touches no bucket")

        // Only b changes (title) → only its bucket.
        var b2 = b
        b2.title = "改"
        model.upsert(
            appKey: "pid:1",
            output: PipelineOutput(entities: [a, b2], relations: [], index: SpatialIndex()),
            meta: meta("pid:1", 1, "A")
        )
        XCTAssertEqual(model.changedRegions(after: v1), ["d2q3"])

        let v2 = model.version
        model.setFrontmost(appKey: "pid:1")
        XCTAssertEqual(model.changedRegions(after: v2), ["sys"])

        let v3 = model.version
        model.removeApp(appKey: "pid:1")
        XCTAssertEqual(model.changedRegions(after: v3), ["d1q2", "d2q3"], "removal logs the emptied buckets")
    }
}
