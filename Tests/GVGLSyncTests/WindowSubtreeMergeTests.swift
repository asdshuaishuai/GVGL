import XCTest
import GVGLCore
import GVGLSync

/// The per-window subtree merge is where V4.1 #1 lived: nested windows
/// (sheets/drawers/Electron inner AXWindows) whose `windowID` points at the
/// nested window used to survive a top-level-id-only filter and duplicate the
/// re-captured copy. It is now pure and directly testable.
final class WindowSubtreeMergeTests: XCTestCase {
    private func entity(_ id: String, role: String = "AXButton", windowID: String? = nil,
                        title: String? = nil) -> Entity {
        Entity(id: id, role: role, title: title, detail: nil, identifier: nil,
               enabled: true, actions: [],
               axParentID: nil, entityParentID: nil, windowID: windowID,
               appID: "pid:1", pid: 1,
               geometry: Geometry(screen: NormRect(x: 0.1, y: 0.1, w: 0.05, h: 0.05),
                                  window: .unit))
    }

    private func output(_ entities: [Entity], cg: Int = 0) -> PipelineOutput {
        PipelineOutput(entities: entities, cgWindowCount: cg)
    }

    // MARK: - ID grammar

    func testNumericPathParsesOnlyPureNumericSuffixes() {
        XCTAssertEqual(WindowSubtreeMerge.numericPath(from: "pid:722:0-2-3"), [0, 2, 3])
        XCTAssertEqual(WindowSubtreeMerge.numericPath(from: "pid:722:0"), [0])
        XCTAssertNil(WindowSubtreeMerge.numericPath(from: "pid:722:root"))
        XCTAssertNil(WindowSubtreeMerge.numericPath(from: "pid:722:mb"))
        XCTAssertNil(WindowSubtreeMerge.numericPath(from: "pid:722:mb-1-0"))
        XCTAssertNil(WindowSubtreeMerge.numericPath(from: "pid:722:0-x"))
        XCTAssertNil(WindowSubtreeMerge.numericPath(from: "not-an-id"))
    }

    func testNamespaceIsPrefixBased() {
        XCTAssertTrue(WindowSubtreeMerge.isInSubtreeNamespace("pid:7:0-2", of: "pid:7:0-2"))
        XCTAssertTrue(WindowSubtreeMerge.isInSubtreeNamespace("pid:7:0-2-3-1", of: "pid:7:0-2"))
        XCTAssertFalse(WindowSubtreeMerge.isInSubtreeNamespace("pid:7:0-3", of: "pid:7:0-2"))
        XCTAssertFalse(WindowSubtreeMerge.isInSubtreeNamespace("pid:7:0", of: "pid:7:0-2"))
        XCTAssertFalse(WindowSubtreeMerge.isInSubtreeNamespace("pid:7:mb-1", of: "pid:7:0-2"))
        XCTAssertFalse(WindowSubtreeMerge.isInSubtreeNamespace("pid:8:0-2", of: "pid:7:0-2"))
    }

    // MARK: - Merge semantics

    /// V4.1 #1, second form: a budget-truncated re-capture produces fewer ids
    /// than the previous sweep, so the nested window's old entity is neither in
    /// the subtree set nor equal to the top-level windowID. Only the namespace
    /// rule catches it; without it the stale sheet survives next to its
    /// refreshed parent.
    func testTruncatedRecaptureDropsStaleNestedWindowEntities() {
        let previous = output([
            entity("pid:1:0", role: "AXWindow", title: "主窗口"),
            entity("pid:1:0-1", title: "按钮"),
            entity("pid:1:0-2", role: "AXWindow", windowID: "pid:1:0-2", title: "内嵌 Sheet"),
        ])
        let truncated = output([
            entity("pid:1:0", role: "AXWindow", title: "主窗口"),
            entity("pid:1:0-1", title: "按钮"),
        ])
        let merged = WindowSubtreeMerge.merge(previous: previous, subtree: truncated,
                                              windowID: "pid:1:0")
        let ids: [String] = merged.entities.map { $0.id }
        XCTAssertEqual(ids, ["pid:1:0", "pid:1:0-1"],
                       "the stale nested-sheet entity must not survive the merge")
    }

    func testMergeKeepsOtherWindowsByteIdentical() {
        let previous = output([
            entity("pid:1:0", role: "AXWindow", title: "主窗口"),
            entity("pid:1:5", role: "AXWindow", windowID: "pid:1:5", title: "另一个窗口"),
            entity("pid:1:5-1", windowID: "pid:1:5", title: "另一窗口的按钮"),
        ])
        let subtree = output([
            entity("pid:1:0", role: "AXWindow", title: "主窗口"),
            entity("pid:1:0-1", title: "按钮"),
        ])
        let merged = WindowSubtreeMerge.merge(previous: previous, subtree: subtree,
                                              windowID: "pid:1:0")
        let ids: [String] = merged.entities.map { $0.id }
        XCTAssertEqual(ids, ["pid:1:0", "pid:1:0-1", "pid:1:5", "pid:1:5-1"])
        XCTAssertEqual(merged.entities.first { $0.id == "pid:1:5-1" }?.title, "另一窗口的按钮")
    }

    func testMergePreservesDiagnostics() {
        let previous = output([entity("pid:1:0")], cg: 7)
        let subtree = output([entity("pid:1:0")])
        let merged = WindowSubtreeMerge.merge(previous: previous, subtree: subtree,
                                              windowID: "pid:1:0")
        XCTAssertEqual(merged.cgWindowCount, 7)
        XCTAssertEqual(merged.axWindowCount, 0)
        XCTAssertEqual(merged.missingWindowTitles, [])
    }
}

final class CaptureGateTests: XCTestCase {
    private let now = Date()

    func testFreshCaptureIsAllowed() {
        XCTAssertTrue(CaptureGate.shouldCapture(now: now, lastCaptured: nil, cooldownUntil: nil,
                                                 minInterval: 0.15, cooldownOnError: 30))
    }

    func testMinIntervalBlocksNotificationStorms() {
        let recent = now.addingTimeInterval(-0.1)
        XCTAssertFalse(CaptureGate.shouldCapture(now: now, lastCaptured: recent, cooldownUntil: nil,
                                                  minInterval: 0.15, cooldownOnError: 30))
        let oldEnough = now.addingTimeInterval(-0.2)
        XCTAssertTrue(CaptureGate.shouldCapture(now: now, lastCaptured: oldEnough, cooldownUntil: nil,
                                                 minInterval: 0.15, cooldownOnError: 30))
    }

    func testCooldownBlocksAfterError() {
        let until = now.addingTimeInterval(30)
        XCTAssertFalse(CaptureGate.shouldCapture(now: now, lastCaptured: nil, cooldownUntil: until,
                                                  minInterval: 0.15, cooldownOnError: 30))
        let expired = now.addingTimeInterval(-1)
        XCTAssertTrue(CaptureGate.shouldCapture(now: now, lastCaptured: nil, cooldownUntil: expired,
                                                 minInterval: 0.15, cooldownOnError: 30))
    }

    /// The original guard is strict `<`; pin values with margin instead of the
    /// exact boundary (Date subtraction is not exact enough to hit it).
    func testMinIntervalBoundary() {
        let inside = now.addingTimeInterval(-0.149)
        XCTAssertFalse(CaptureGate.shouldCapture(now: now, lastCaptured: inside, cooldownUntil: nil,
                                                  minInterval: 0.15, cooldownOnError: 30))
        let outside = now.addingTimeInterval(-0.151)
        XCTAssertTrue(CaptureGate.shouldCapture(now: now, lastCaptured: outside, cooldownUntil: nil,
                                                 minInterval: 0.15, cooldownOnError: 30))
    }
}
