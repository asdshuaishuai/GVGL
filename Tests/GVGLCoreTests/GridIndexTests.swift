import XCTest
@testable import GVGLCore

final class GridIndexTests: XCTestCase {
    private func entity(_ id: String, centerX: Double, centerY: Double) -> Entity {
        let screen = NormRect(x: centerX - 0.01, y: centerY - 0.01, w: 0.02, h: 0.02)
        return Entity(
            id: id, role: "AXButton", title: nil, detail: nil, identifier: nil,
            enabled: true, actions: [],
            axParentID: nil, entityParentID: nil, windowID: "w",
            appID: "pid:1", pid: 1,
            geometry: Geometry(screen: screen, window: screen)
        )
    }

    func testCellKey() {
        XCTAssertEqual(SpatialIndex.cellKey(centerX: 0.1, centerY: 0.1, gridSize: 4), "r0c0")
        XCTAssertEqual(SpatialIndex.cellKey(centerX: 0.9, centerY: 0.9, gridSize: 4), "r3c3")
        XCTAssertEqual(SpatialIndex.cellKey(centerX: 0.5, centerY: 0.5, gridSize: 4), "r2c2")
        XCTAssertEqual(SpatialIndex.cellKey(centerX: -0.5, centerY: -0.5, gridSize: 4), "r0c0", "off-screen clamps to edge cell")
        XCTAssertEqual(SpatialIndex.cellKey(centerX: 1.5, centerY: 1.5, gridSize: 4), "r3c3")
        XCTAssertEqual(SpatialIndex.cellKey(centerX: 0.5, centerY: 0.5, gridSize: 2), "r1c1")
    }

    func testBuildWithGrid() {
        let es = [
            entity("a", centerX: 0.1, centerY: 0.1),
            entity("b", centerX: 0.9, centerY: 0.9),
            entity("c", centerX: 0.15, centerY: 0.12),
        ]
        let idx = SpatialIndex.build(from: es, gridSize: 4)
        XCTAssertEqual(idx.byGrid["r0c0"], ["a", "c"])
        XCTAssertEqual(idx.byGrid["r3c3"], ["b"])
        XCTAssertEqual(idx.gridSize, 4)
    }

    func testBuilderSeam() {
        let es = [entity("a", centerX: 0.1, centerY: 0.1)]
        let grid = GridIndexBuilder(gridSize: 2).build(from: es)
        XCTAssertEqual(grid.gridSize, 2)
        XCTAssertFalse(grid.byGrid.isEmpty)

        let linear = LinearScanIndexBuilder().build(from: es)
        XCTAssertEqual(linear.gridSize, 0)
        XCTAssertTrue(linear.byGrid.isEmpty)
        XCTAssertEqual(linear.byRole["AXButton"], ["a"])
    }

    func testBackwardCompatibleDecode() {
        // V1 frames carry no byGrid/gridSize keys.
        let old = #"{"byRegion":{"q1":["a"]},"byRole":{"AXButton":["a"]},"byWindow":{"w":["a"]},"byApp":{"pid:1":["a"]}}"#
        let decoded = try! JSONDecoder.gvgl.decode(SpatialIndex.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.gridSize, 4)
        XCTAssertTrue(decoded.byGrid.isEmpty)
        XCTAssertEqual(decoded.byRole["AXButton"], ["a"])
    }
}

final class CGWindowCrossCheckTests: XCTestCase {
    private let screen = ScreenInfo(width: 3440, height: 1440)

    private final class MockCGProvider: CGWindowProviding, @unchecked Sendable {
        var windows: [CGWindowInfo] = []
        func onScreenWindows(pid: Int32) -> [CGWindowInfo] { windows }
    }

    private func appSnapshot(pid: Int32, windows: [CGWindowInfo], makeNodes: @escaping () -> [AXNode]) -> AXAppSnapshot {
        // This suite exercises the --cg-check diagnostics path → flag on.
        var s = AXAppSnapshot(
            appKey: "pid:\(pid)", pid: pid, nodes: makeNodes(),
            visited: 0, truncated: false, error: nil, elapsed: 0,
            cgDiagnosticsEnabled: true
        )
        s.cgWindows = windows
        return s
    }

    private func singleWindowNodes(pid: Int32) -> [AXNode] {
        let key = "pid:\(pid)"
        return [AXNode(
            id: "\(key):0", role: "AXWindow", title: "主窗",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            parentID: "\(key):root", windowID: "\(key):0"
        )]
    }

    func testMissingWindowDetected() {
        let provider = MockCGProvider()
        provider.windows = [
            CGWindowInfo(id: 1, name: "主窗", bounds: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 0),
            CGWindowInfo(id: 2, name: "隐形窗", bounds: CGRect(x: 1000, y: 100, width: 400, height: 300), layer: 0),
        ]
        let snapshot = appSnapshot(pid: 7, windows: provider.windows) { [self] in singleWindowNodes(pid: 7) }
        let out = Pipeline(screen: screen).process(snapshot)

        XCTAssertEqual(out.axWindowCount, 1)
        XCTAssertEqual(out.cgWindowCount, 2)
        XCTAssertEqual(out.missingWindowTitles, ["隐形窗"])
    }

    func testAllWindowsMatched() {
        let provider = MockCGProvider()
        provider.windows = [
            CGWindowInfo(id: 1, name: "主窗", bounds: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 0),
        ]
        let snapshot = appSnapshot(pid: 7, windows: provider.windows) { [self] in singleWindowNodes(pid: 7) }
        let out = Pipeline(screen: screen).process(snapshot)
        XCTAssertEqual(out.cgWindowCount, 1)
        XCTAssertTrue(out.missingWindowTitles.isEmpty)
    }

    func testNoProbeData() {
        let snapshot = appSnapshot(pid: 7, windows: []) { [self] in singleWindowNodes(pid: 7) }
        let out = Pipeline(screen: screen).process(snapshot)
        XCTAssertEqual(out.cgWindowCount, 0)
        XCTAssertEqual(out.axWindowCount, 1)
        XCTAssertTrue(out.missingWindowTitles.isEmpty)
    }
}
