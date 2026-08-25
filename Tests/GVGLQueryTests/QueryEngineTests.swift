import XCTest
@testable import GVGLQuery
@testable import GVGLCore

final class QueryEngineTests: XCTestCase {
    private let screen = ScreenInfo(width: 3440, height: 1440)

    private func entity(
        _ id: String,
        role: String = "AXButton",
        title: String? = nil,
        detail: String? = nil,
        identifier: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        enabled: Bool = true,
        actions: [String] = ["AXPress"],
        rect: NormRect = NormRect(x: 0.2, y: 0.2, w: 0.05, h: 0.05),
        windowID: String? = "w",
        appID: String = "pid:1",
        displayID: Int? = nil
    ) -> Entity {
        Entity(
            id: id, role: role, title: title, detail: detail, identifier: identifier,
            value: value, placeholder: placeholder,
            enabled: enabled, actions: actions,
            axParentID: nil, entityParentID: windowID, windowID: windowID,
            appID: appID, pid: 1,
            appName: nil, displayID: displayID,
            geometry: Geometry(screen: rect, window: rect)
        )
    }

    private func frame(_ entities: [Entity]) -> GVGLFrame {
        let scene = SceneTree.build(entities: entities)
        return GVGLFrame(
            frameID: "t", version: 1, createdAt: Date(), syncedAt: Date(),
            screen: screen,
            scene: [SceneApp(appKey: "pid:1", pid: 1, bundleID: nil, name: "A",
                             status: .synced, capturedAt: Date(),
                             entityCount: entities.count, children: scene)],
            index: SpatialIndex.build(from: entities, gridSize: 0),
            status: .ok
        )
    }

    private func score(_ e: Entity, _ params: QueryParams, all: [Entity] = []) -> (score: Double, breakdown: [String: Double]) {
        var pool = all
        if !pool.contains(where: { $0.id == e.id }) { pool.append(e) }
        let byID = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
        let ref = params.refID.flatMap { byID[$0] }
        return QueryEngine.score(entity: e, params: params, ref: ref,
                                 refRegion: ref?.geometry.region.rawValue, byID: byID)
    }

    func testSemanticScoring() {
        let e = entity("a", title: "登录按钮")
        XCTAssertEqual(score(e, QueryParams(label: "登录按钮")).breakdown["semantic"] ?? -1, 1.0)
        XCTAssertEqual(score(e, QueryParams(label: "登录")).breakdown["semantic"] ?? -1, 0.7)
        let d = entity("b", detail: "点击以登录")
        XCTAssertEqual(score(d, QueryParams(label: "登录")).breakdown["semantic"] ?? -1, 0.6)
        let i = entity("c", identifier: "btn_login")
        XCTAssertEqual(score(i, QueryParams(label: "login")).breakdown["semantic"] ?? -1, 0.5)
        XCTAssertEqual(score(e, QueryParams(label: "不存在")).breakdown["semantic"] ?? -1, 0.0)
    }

    func testValueAndPlaceholderScoring() {
        // Placeholder beats detail (0.65), value sits between detail and
        // identifier (0.55) — typed content / checkbox state is searchable.
        let p = entity("p", placeholder: "搜索网页")
        XCTAssertEqual(score(p, QueryParams(label: "搜索")).breakdown["semantic"] ?? -1, 0.65)
        let v = entity("v", value: "kelthas@example.com")
        XCTAssertEqual(score(v, QueryParams(label: "kelthas")).breakdown["semantic"] ?? -1, 0.55)
        // Title still wins over value.
        let both = entity("b", title: "邮箱", value: "kelthas")
        XCTAssertEqual(score(both, QueryParams(label: "邮箱")).breakdown["semantic"] ?? -1, 1.0)
        // Value beats identifier when both match (value checked first).
        let vi = entity("vi", identifier: "token_field", value: "token")
        XCTAssertEqual(score(vi, QueryParams(label: "token")).breakdown["semantic"] ?? -1, 0.55)
    }

    func testExpandedCompatibleRoles() {
        let textArea = entity("ta", role: "AXTextArea")
        XCTAssertEqual(score(textArea, QueryParams(role: "AXTextField")).breakdown["role"] ?? -1, 0.6)
        let popUp = entity("pu", role: "AXPopUpButton")
        XCTAssertEqual(score(popUp, QueryParams(role: "AXComboBox")).breakdown["role"] ?? -1, 0.6)
        let secure = entity("sf", role: "AXSecureTextField")
        XCTAssertEqual(score(secure, QueryParams(role: "AXTextField")).breakdown["role"] ?? -1, 0.6)
    }

    func testRoleScoring() {
        let btn = entity("a", role: "AXButton")
        XCTAssertEqual(score(btn, QueryParams(role: "AXButton")).breakdown["role"] ?? -1, 1.0)
        // Compatible: Button ↔ MenuItem.
        XCTAssertEqual(score(btn, QueryParams(role: "AXMenuItem")).breakdown["role"] ?? -1, 0.6)
        XCTAssertEqual(score(btn, QueryParams(role: "AXTextField")).breakdown["role"] ?? -1, 0.0)
    }

    func testSpatialScoring() {
        // V4: spatial relations are computed geometrically from rects.
        let ref = entity("ref", rect: NormRect(x: 0.2, y: 0.2, w: 0.05, h: 0.05))
        let right = entity("right", rect: NormRect(x: 0.3, y: 0.2, w: 0.05, h: 0.05))
        let left = entity("left", rect: NormRect(x: 0.1, y: 0.2, w: 0.05, h: 0.05))
        let near = entity("near", rect: NormRect(x: 0.24, y: 0.2, w: 0.02, h: 0.02))
        let sameQuad = entity("sq", rect: NormRect(x: 0.05, y: 0.05, w: 0.02, h: 0.02))
        let all = [ref, right, left, near, sameQuad]

        XCTAssertEqual(score(right, QueryParams(refID: "ref", refDir: "rightOf"), all: all).breakdown["spatial"] ?? -1, 1.0)
        XCTAssertEqual(score(left, QueryParams(refID: "ref", refDir: "rightOf"), all: all).breakdown["spatial"] ?? -1, 0.5,
                       "left of ref and same quadrant → quadrant tier only")
        XCTAssertEqual(score(left, QueryParams(refID: "ref", refDir: "leftOf"), all: all).breakdown["spatial"] ?? -1, 1.0)
        // Overlapping pair within near distance → 0.7 tier for a direction query.
        XCTAssertEqual(score(near, QueryParams(refID: "ref", refDir: "rightOf"), all: all).breakdown["spatial"] ?? -1, 0.7)
        // Explicit near query → near pair scores the full 1.0.
        XCTAssertEqual(score(near, QueryParams(refID: "ref", refDir: "near"), all: all).breakdown["spatial"] ?? -1, 1.0)
        // Same quadrant as the REFERENCE entity (§4.2).
        XCTAssertEqual(score(sameQuad, QueryParams(refID: "ref", refDir: "rightOf"), all: all).breakdown["spatial"] ?? -1, 0.5)
        // R12: containment prunes the direction tier even when geometry
        // would satisfy it (child poking out of its parent's right edge).
        let container = entity("box", rect: NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.2))
        let child = Entity(
            id: "child", role: "AXButton", title: nil, detail: nil, identifier: nil,
            enabled: true, actions: ["AXPress"],
            axParentID: "box", entityParentID: "box", windowID: "w",
            appID: "pid:1", pid: 1,
            geometry: Geometry(screen: NormRect(x: 0.35, y: 0.12, w: 0.05, h: 0.05),
                               window: NormRect(x: 0.35, y: 0.12, w: 0.05, h: 0.05))
        )
        let pool = all + [container, child]
        let pruned = score(child, QueryParams(refID: "box", refDir: "rightOf"), all: pool).breakdown["spatial"] ?? -1
        XCTAssertLessThan(pruned, 1.0, "contained entity must not match the direction tier")
    }

    func testSizeAndTopology() {
        let good = entity("a", rect: NormRect(x: 0.2, y: 0.2, w: 0.05, h: 0.05))
        XCTAssertEqual(score(good, QueryParams()).breakdown["size"] ?? -1, 1.0)
        let big = entity("b", rect: NormRect(x: 0.2, y: 0.2, w: 0.5, h: 0.5))
        XCTAssertEqual(score(big, QueryParams()).breakdown["size"] ?? -1, 0.2)

        // Topology: window + enabled + actions → 1.0.
        XCTAssertEqual(score(good, QueryParams()).breakdown["topology"] ?? -1, 1.0)
        let disabled = entity("c", enabled: false, actions: [])
        XCTAssertEqual(score(disabled, QueryParams()).breakdown["topology"] ?? -1, 0.3)
    }

    func testCompositeScore() {
        let e = entity("a", role: "AXButton", title: "登录", rect: NormRect(x: 0.2, y: 0.2, w: 0.05, h: 0.05))
        let params = QueryParams(role: "AXButton", label: "登录")
        let (total, b) = score(e, params)
        // Exact title match → semantic 1.0.
        XCTAssertEqual(total, 1.0 * 0.35 + 1.0 * 0.20 + 1.0 * 0.10 + 1.0 * 0.10, accuracy: 1e-9)
        XCTAssertEqual(b["semantic"], 1.0)
    }

    func testStatusGates() {
        let hit = entity("a", role: "AXButton", title: "登录", rect: NormRect(x: 0.2, y: 0.2, w: 0.05, h: 0.05))
        let miss = entity("b", role: "AXButton", title: "其他", rect: NormRect(x: 0.2, y: 0.2, w: 0.05, h: 0.05))

        XCTAssertEqual(QueryEngine.query(frame: frame([hit]), params: QueryParams(role: "AXButton", label: "登录")).status, .hit)
        // Role+size+topology floor is 0.4 → title mismatch stays ambiguous.
        XCTAssertEqual(QueryEngine.query(frame: frame([miss]), params: QueryParams(role: "AXButton", label: "登录")).status, .ambiguous)
        XCTAssertEqual(QueryEngine.query(frame: frame([]), params: QueryParams(role: "AXButton", label: "登录")).status, .notFound)
        // ax_weak fires only for weak elements (small/disabled/actionless →
        // score < 0.4): titled or healthy elements stay ambiguous/notFound.
        let titled = entity("c", role: "AXImage", title: "有标题", rect: NormRect(x: 0.2, y: 0.2, w: 0.05, h: 0.05))
        XCTAssertEqual(QueryEngine.query(frame: frame([titled]), params: QueryParams(role: "AXImage", label: "无")).status, .ambiguous)
        let weak = entity("d", role: "AXImage", title: nil, enabled: false, actions: [],
                          rect: NormRect(x: 0.2, y: 0.2, w: 0.0002, h: 0.0002))
        XCTAssertEqual(QueryEngine.query(frame: frame([weak]), params: QueryParams(role: "AXImage", label: "无")).status, .axWeak)
    }

    func testPixelCenter() {
        let e = entity("a", rect: NormRect(x: 0.49, y: 0.64, w: 0.02, h: 0.02))
        let p = QueryEngine.pixelCenter(of: e, screen: screen)
        XCTAssertEqual(p.x, 0.5 * 3440, accuracy: 0.01)
        XCTAssertEqual(p.y, 0.65 * 1440, accuracy: 0.01)
    }

    /// V5: display filter narrows candidates to one physical display —
    /// "display 2 的 q2" becomes a two-keyword query.
    func testDisplayFilter() {
        let a = entity("a", title: "按钮", displayID: 1)
        let b = entity("b", title: "按钮", displayID: 2)
        let f = frame([a, b])

        let onTwo = QueryEngine.query(frame: f, params: QueryParams(label: "按钮", display: 2, top: 5))
        XCTAssertEqual(onTwo.ranked.map(\.id), ["b"])

        let onOne = QueryEngine.query(frame: f, params: QueryParams(label: "按钮", display: 1, top: 5))
        XCTAssertEqual(onOne.ranked.map(\.id), ["a"])

        let unknown = QueryEngine.query(frame: f, params: QueryParams(label: "按钮", display: 7, top: 5))
        XCTAssertEqual(unknown.status, .notFound)
    }
}


final class InstructionParserTests: XCTestCase {
    func testClickButton() throws {
        let p = try InstructionParser.parse("点击 登录 按钮")
        XCTAssertEqual(p.action, .click)
        XCTAssertEqual(p.params.label, "登录")
        XCTAssertEqual(p.params.role, "AXButton")
    }

    func testGluedCompoundWithRegion() throws {
        let p = try InstructionParser.parse("点击右上角的登录按钮")
        XCTAssertEqual(p.action, .click)
        XCTAssertEqual(p.params.region, "q2")
        XCTAssertEqual(p.params.label, "登录")
        XCTAssertEqual(p.params.role, "AXButton")
    }

    func testTwoStageRelation() throws {
        let p = try InstructionParser.parse("在 搜索框 右侧的 关闭 按钮")
        XCTAssertEqual(p.action, .query)
        XCTAssertEqual(p.params.refDir, "rightOf")
        XCTAssertEqual(p.params.label, "关闭")
        XCTAssertEqual(p.params.role, "AXButton")
        XCTAssertEqual(p.reference?.label, "搜索框")
        XCTAssertEqual(p.reference?.role, "AXTextField")
    }

    func testLabelOnly() throws {
        let p = try InstructionParser.parse("点击 退出登录")
        XCTAssertEqual(p.action, .click)
        XCTAssertEqual(p.params.label, "退出登录")
        XCTAssertNil(p.params.role)
    }

    func testCLIPassthrough() throws {
        let p = try InstructionParser.parse("query --role AXButton --label 登录 --region q2 --top 3")
        XCTAssertEqual(p.action, .query)
        XCTAssertEqual(p.params.role, "AXButton")
        XCTAssertEqual(p.params.label, "登录")
        XCTAssertEqual(p.params.region, "q2")
        XCTAssertEqual(p.params.top, 3)
    }

    func testCLIClickRelation() throws {
        let p = try InstructionParser.parse("点击 --role AXButton --reference pid:1:0-1 --relation right-of")
        XCTAssertEqual(p.action, .click)
        XCTAssertEqual(p.params.refID, "pid:1:0-1")
        XCTAssertEqual(p.params.refDir, "rightOf")
    }

    func testEmptyThrows() {
        XCTAssertThrowsError(try InstructionParser.parse("   ")) { error in
            XCTAssertEqual(error as? ParseError, .empty)
        }
    }

    func testInspectWord() throws {
        let p = try InstructionParser.parse("查找 设置 窗口")
        XCTAssertEqual(p.action, .query)
        XCTAssertEqual(p.params.label, "设置")
        XCTAssertEqual(p.params.role, "AXWindow")
    }
}
