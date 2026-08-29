import XCTest
@testable import GVGLCore

/// V5 Display Space: per-display normalization, display-relative quadrant
/// labels, the coarse desktop map, and backward frame decode compatibility.
final class DisplaySpaceTests: XCTestCase {
    /// Main display 3440x1440 at origin; secondary 1920x1080 to its left
    /// (global x ∈ [-1920, 0)) — the layout from the live audit machine.
    private let dual = ScreenInfo(
        width: 3440, height: 1440, scaleFactor: 2.0,
        displays: [
            DisplayInfo(id: 1, x: 0, y: 0, width: 3440, height: 1440, scaleFactor: 2.0),
            DisplayInfo(id: 2, x: -1920, y: 0, width: 1920, height: 1080, scaleFactor: 2.0),
        ]
    )
    private let single = ScreenInfo(width: 3440, height: 1440)

    private func windowSnapshot(appKey: String, pid: Int32,
                                frame: CGRect, title: String) -> AXAppSnapshot {
        AXAppSnapshot(
            appKey: appKey, pid: pid,
            nodes: [AXNode(
                id: "\(appKey):0", role: "AXWindow", title: title,
                frame: frame, parentID: "\(appKey):root", windowID: "\(appKey):0"
            )],
            visited: 1, truncated: false, error: nil, elapsed: 0
        )
    }

    /// An element centered in the secondary display's right-bottom quadrant
    /// must label q4 — not the q1/q3 garbage that main-screen normalization
    /// produced for every secondary-display element before V5.
    func testSecondaryDisplayQuadrants() {
        // Window covers the right 60% × bottom 60% of the secondary display:
        // global pixels x ∈ [-1152, 0), y ∈ [432, 1080).
        let snapshot = windowSnapshot(
            appKey: "pid:9", pid: 9,
            frame: CGRect(x: -1152, y: 432, width: 1152, height: 648),
            title: "副屏右下"
        )
        let out = Pipeline(screen: dual).process(snapshot)
        let e = out.entities.first { $0.id == "pid:9:0" }!
        // Display Space: per-display normalization in [0,1].
        XCTAssertEqual(e.geometry.display.x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(e.geometry.display.y, 0.4, accuracy: 1e-6)
        XCTAssertEqual(e.geometry.display.w, 0.6, accuracy: 1e-6)
        XCTAssertEqual(e.geometry.display.h, 0.6, accuracy: 1e-6)
        XCTAssertEqual(e.geometry.region, .q4, "right-bottom of ITS OWN display")
        XCTAssertEqual(e.geometry.region9, .rightBottom)
        // Screen Space: still global main-normalized (negative) — execution
        // path (toPixels) semantics unchanged.
        XCTAssertEqual(e.geometry.screen.x, -1152.0 / 3440.0, accuracy: 1e-6)
        XCTAssertEqual(e.displayID, 2)
    }

    /// Same pipeline, main display: display space equals screen space and the
    /// labels keep their V1 meaning (single-display behavior is unchanged).
    func testMainDisplayDisplaySpaceEqualsScreenSpace() {
        let snapshot = windowSnapshot(
            appKey: "pid:10", pid: 10,
            frame: CGRect(x: 1720, y: 720, width: 344, height: 144),
            title: "主屏右下"
        )
        let out = Pipeline(screen: dual).process(snapshot)
        let e = out.entities.first { $0.id == "pid:10:0" }!
        XCTAssertEqual(e.geometry.display, e.geometry.screen)
        XCTAssertEqual(e.geometry.region, .q4)
        XCTAssertEqual(e.displayID, 1)
    }

    /// Single-display screens (no displays[]) fall back: display space =
    /// screen space, exactly the pre-V5 semantics.
    func testNoDisplayInfoFallsBackToScreenSpace() {
        let snapshot = windowSnapshot(
            appKey: "pid:11", pid: 11,
            frame: CGRect(x: 0, y: 0, width: 344, height: 144),
            title: "单屏"
        )
        let out = Pipeline(screen: single).process(snapshot)
        let e = out.entities.first { $0.id == "pid:11:0" }!
        XCTAssertEqual(e.geometry.display, e.geometry.screen)
        XCTAssertEqual(e.geometry.region, .q1)
        XCTAssertNil(e.displayID)
    }

    /// Pre-V5 frames carry no "display" key in geometry — decode must fall
    /// back to screen space (their region labels were computed that way).
    func testGeometryDecodeWithoutDisplayKey() throws {
        let json = """
        {"screen":{"x":0.1,"y":0.1,"w":0.2,"h":0.2},
         "window":{"x":0.0,"y":0.0,"w":1.0,"h":1.0},
         "centerX":0.2,"centerY":0.2,"area":0.04,"aspect":1.0,
         "region":"q1","region9":"leftTop"}
        """
        let g = try JSONDecoder.gvgl.decode(Geometry.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(g.display, g.screen)
        XCTAssertEqual(g.local, .unit)
        // Round-trip re-encodes WITH display (V5 frames always carry it).
        let re = try JSONDecoder.gvgl.decode(
            Geometry.self,
            from: JSONEncoder.gvgl.encode(g)
        )
        XCTAssertEqual(re, g)
    }

    /// The coarse map: displays indexed (main first), windows front-to-back
    /// with per-display quadrant labels and frontmost flag.
    func testDesktopMap() {
        let mainWin = windowSnapshot(
            appKey: "pid:20", pid: 20,
            frame: CGRect(x: 1720, y: 720, width: 689, height: 288),
            title: "主"
        )
        let secondWin = windowSnapshot(
            appKey: "pid:21", pid: 21,
            frame: CGRect(x: -1920, y: 0, width: 768, height: 432),
            title: "副"
        )
        let mainOut = Pipeline(screen: dual).process(mainWin)
        let secondOut = Pipeline(screen: dual).process(secondWin)
        var mainEntity = mainOut.entities[0]
        mainEntity.zIndex = 3
        var secondEntity = secondOut.entities[0]
        secondEntity.zIndex = 1

        let scene = [
            SceneApp(appKey: "pid:20", pid: 20, bundleID: nil, name: "主应用",
                     status: .synced, capturedAt: Date(), entityCount: 1,
                     children: SceneTree.build(entities: [mainEntity])),
            SceneApp(appKey: "pid:21", pid: 21, bundleID: nil, name: "副应用",
                     status: .synced, capturedAt: Date(), entityCount: 1,
                     children: SceneTree.build(entities: [secondEntity])),
        ]
        let frame = GVGLFrame(
            frameID: "t", version: 42, createdAt: Date(), syncedAt: Date(),
            screen: dual, scene: scene,
            index: SpatialIndex.build(from: [mainEntity, secondEntity], gridSize: 0),
            frontmostApp: "pid:21",
            status: .ok
        )

        let map = frame.desktopMap
        XCTAssertEqual(map.version, 42)
        XCTAssertEqual(map.displays.map(\.index), [0, 1])
        XCTAssertEqual(map.displays.map(\.id), [1, 2])
        XCTAssertEqual(map.displays[1].x, -1920)

        // Front-to-back by zIndex, then id for determinism.
        XCTAssertEqual(map.windows.map(\.id), ["pid:21:0", "pid:20:0"])
        let front = map.windows[0]
        XCTAssertEqual(front.display, 1, "secondary display index")
        XCTAssertEqual(front.region, .q1, "top-left of the secondary display")
        XCTAssertTrue(front.frontmost, "belongs to frontmostApp pid:21")
        XCTAssertEqual(front.rect, secondEntity.geometry.display)
        XCTAssertFalse(map.windows[1].frontmost)

        // Map serializes through the standard encoder (wire compatibility).
        XCTAssertNoThrow(try JSONEncoder.gvgl.encode(map))
    }

    /// Empty displays[] synthesizes a single main display so the map is always
    /// well-formed.
    func testDesktopMapSynthesizesDisplayWhenEmpty() {
        let out = Pipeline(screen: single).process(
            windowSnapshot(appKey: "pid:30", pid: 30,
                           frame: CGRect(x: 0, y: 0, width: 344, height: 144),
                           title: "w")
        )
        let frame = GVGLFrame(
            frameID: "t", version: 1, createdAt: Date(), syncedAt: Date(),
            screen: single,
            scene: [SceneApp(appKey: "pid:30", pid: 30, bundleID: nil, name: nil,
                             status: .synced, capturedAt: Date(), entityCount: 1,
                             children: SceneTree.build(entities: out.entities))],
            index: SpatialIndex(), status: .ok
        )
        let map = frame.desktopMap
        XCTAssertEqual(map.displays.count, 1)
        XCTAssertEqual(map.displays[0].index, 0)
        XCTAssertEqual(map.windows.first?.display, 0)
    }
}
