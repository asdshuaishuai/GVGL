import XCTest
@testable import GVGLCore

final class PipelineTests: XCTestCase {
    private let screen = ScreenInfo(width: 3440, height: 1440)

    /// Fixture AX tree:
    /// root (pid:1:root)
    /// └── AXWindow "main" (0, 30, 800, 600)          → pid:1:0
    ///     ├── AXGroup (dropped)                        → pid:1:0-0
    ///     │   └── AXButton "登录" (100, 100, 80, 40)   → pid:1:0-0-0
    ///     │       └── AXStaticText "登录" (110,110,60,20) → pid:1:0-0-0-0
    ///     ├── AXTextField "username" (100, 200, 200, 30) → pid:1:0-1
    ///     └── AXWindow "hidden" (frame zero)          → dropped by R3
    private func fixture() -> AXAppSnapshot {
        let appKey = "pid:1"
        let staticText = AXNode(
            id: "\(appKey):0-0-0-0", role: "AXStaticText", title: "登录",
            frame: CGRect(x: 110, y: 110, width: 60, height: 20),
            parentID: "\(appKey):0-0-0", windowID: "\(appKey):0"
        )
        let button = AXNode(
            id: "\(appKey):0-0-0", role: "AXButton", title: "登录",
            enabled: true, actions: ["AXPress"],
            frame: CGRect(x: 100, y: 100, width: 80, height: 40),
            parentID: "\(appKey):0-0", windowID: "\(appKey):0",
            children: [staticText]
        )
        let group = AXNode(
            id: "\(appKey):0-0", role: "AXGroup",
            frame: CGRect(x: 90, y: 90, width: 120, height: 60),
            parentID: "\(appKey):0", windowID: "\(appKey):0",
            children: [button]
        )
        let textField = AXNode(
            id: "\(appKey):0-1", role: "AXTextField", title: "username",
            enabled: true,
            frame: CGRect(x: 100, y: 200, width: 200, height: 30),
            parentID: "\(appKey):0", windowID: "\(appKey):0"
        )
        let hiddenWindow = AXNode(
            id: "\(appKey):0-2", role: "AXWindow",
            frame: .zero,
            parentID: "\(appKey):root", windowID: nil
        )
        let window = AXNode(
            id: "\(appKey):0", role: "AXWindow", title: "main",
            frame: CGRect(x: 0, y: 30, width: 800, height: 600),
            parentID: "\(appKey):root", windowID: "\(appKey):0",
            children: [group, textField]
        )
        let root = AXNode(
            id: "\(appKey):root", role: nil,
            frame: nil, parentID: nil, windowID: nil,
            children: [window, hiddenWindow]
        )
        return AXAppSnapshot(
            appKey: appKey, pid: 1, nodes: [root],
            visited: 7, truncated: false, error: nil, elapsed: 0
        )
    }

    func testEntityExtraction() {
        let out = Pipeline(screen: screen).process(fixture())
        let ids = Set(out.entities.map(\.id))
        XCTAssertEqual(ids, ["pid:1:0", "pid:1:0-0-0", "pid:1:0-0-0-0", "pid:1:0-1"])
        // AXGroup dropped; zero-frame window dropped.
        XCTAssertFalse(ids.contains("pid:1:0-0"))
        XCTAssertFalse(ids.contains("pid:1:0-2"))
    }

    func testEntityParentAncestry() {
        let out = Pipeline(screen: screen).process(fixture())
        let byID = Dictionary(uniqueKeysWithValues: out.entities.map { ($0.id, $0) })

        // Button's AX parent is the (non-entity) group → nearest entity ancestor is the window.
        XCTAssertEqual(byID["pid:1:0-0-0"]?.entityParentID, "pid:1:0")
        XCTAssertEqual(byID["pid:1:0-0-0-0"]?.entityParentID, "pid:1:0-0-0")
        XCTAssertEqual(byID["pid:1:0-1"]?.entityParentID, "pid:1:0")
    }

    func testWindowSpaceNormalization() {
        let out = Pipeline(screen: screen).process(fixture())
        guard let button = out.entities.first(where: { $0.id == "pid:1:0-0-0" }) else {
            return XCTFail("button missing")
        }
        // Window screen rect: (0, 30/1440, 800/3440, 600/1440).
        // Button screen rect: (100/3440, 100/1440, 80/3440, 40/1440).
        XCTAssertEqual(button.geometry.window.x, 0.125, accuracy: 1e-4)
        XCTAssertEqual(button.geometry.window.y, 0.1167, accuracy: 1e-4)
        XCTAssertEqual(button.geometry.window.w, 0.1, accuracy: 1e-4)
        XCTAssertEqual(button.geometry.window.h, 0.0667, accuracy: 1e-4)

        // Window entity's own window space is unit rect.
        let win = out.entities.first { $0.id == "pid:1:0" }
        XCTAssertEqual(win?.geometry.window, .unit)
    }

    /// V3 local space: rect in the nearest entity ancestor's coordinate
    /// system. Fixture: StaticText (110,110,60,20) inside Button
    /// (100,100,80,40) → local (0.125, 0.25, 0.75, 0.5); parentless
    /// entities (window root) keep the unit rect.
    func testLocalSpaceNormalization() {
        let out = Pipeline(screen: screen).process(fixture())
        let byID = Dictionary(uniqueKeysWithValues: out.entities.map { ($0.id, $0) })

        let text = byID["pid:1:0-0-0-0"]
        XCTAssertEqual(text?.entityParentID, "pid:1:0-0-0")
        XCTAssertEqual(text?.geometry.local.x ?? -1, 0.125, accuracy: 1e-4)
        XCTAssertEqual(text?.geometry.local.y ?? -1, 0.25, accuracy: 1e-4)
        XCTAssertEqual(text?.geometry.local.w ?? -1, 0.75, accuracy: 1e-4)
        XCTAssertEqual(text?.geometry.local.h ?? -1, 0.5, accuracy: 1e-4)

        // Button's nearest entity ancestor is the window → local == window space.
        let button = byID["pid:1:0-0-0"]
        XCTAssertEqual(button?.geometry.local, button?.geometry.window)

        // Window root has no entity parent → unit rect.
        XCTAssertEqual(byID["pid:1:0"]?.geometry.local, .unit)
    }

    func testRelations() {
        let out = Pipeline(screen: screen).process(fixture())
        let rs = Set(out.relations)

        XCTAssertTrue(rs.contains(Relation(type: .inside, from: "pid:1:0-0-0", to: "pid:1:0")))
        XCTAssertTrue(rs.contains(Relation(type: .inside, from: "pid:1:0-0-0-0", to: "pid:1:0-0-0")))
        XCTAssertTrue(rs.contains(Relation(type: .contains, from: "pid:1:0", to: "pid:1:0-0-0")))
        // Button (bottom 0.1833) above text field (top 0.3167).
        XCTAssertTrue(rs.contains(Relation(type: .above, from: "pid:1:0-0-0", to: "pid:1:0-1")))
        // Static text inside button → no direction relation between them.
        XCTAssertFalse(rs.contains {
            let pair = Set([$0.from, $0.to]) == Set(["pid:1:0-0-0", "pid:1:0-0-0-0"])
            return pair && ($0.type == .above || $0.type == .below
                || $0.type == .leftOf || $0.type == .rightOf)
        })
    }

    func testEntityAppNamePropagation() {
        let out = Pipeline(screen: screen).process(fixture())
        let byID = Dictionary(uniqueKeysWithValues: out.entities.map { ($0.id, $0) })
        XCTAssertEqual(byID["pid:1:0"]?.appName, nil, "fixture snapshot has no appName")
    }

    func testAppNameFilledFromSnapshot() {
        var snapshot = fixture()
        snapshot.appName = "测试应用"
        let out = Pipeline(screen: screen).process(snapshot)
        XCTAssertTrue(out.entities.allSatisfy { $0.appName == "测试应用" })
    }

    func testIndex() {
        let out = Pipeline(screen: screen).process(fixture())
        XCTAssertEqual(out.index.byRole["AXButton"], ["pid:1:0-0-0"])
        XCTAssertEqual(out.index.byWindow["pid:1:0"], [
            "pid:1:0", "pid:1:0-0-0", "pid:1:0-0-0-0", "pid:1:0-1"
        ])
        XCTAssertEqual(out.index.byApp["pid:1"], [
            "pid:1:0", "pid:1:0-0-0", "pid:1:0-0-0-0", "pid:1:0-1"
        ])
        XCTAssertEqual(out.index.byRegion["q1"], [
            "pid:1:0", "pid:1:0-0-0", "pid:1:0-0-0-0", "pid:1:0-1"
        ])
    }

    func testSecondaryDisplayEntityUsesMainScreenNormalization() {
        // Two displays: main (0,0,3440,1440), secondary left of it (-1280,0,1280,1440).
        let multiScreen = ScreenInfo(
            width: 3440, height: 1440, scaleFactor: 1,
            displays: [
                DisplayInfo(id: 1, x: 0, y: 0, width: 3440, height: 1440),
                DisplayInfo(id: 2, x: -1280, y: 0, width: 1280, height: 1440),
            ]
        )
        let key = "pid:9"
        let button = AXNode(
            id: "\(key):0-0", role: "AXButton", title: "次屏按钮",
            frame: CGRect(x: -1000, y: 200, width: 100, height: 50),
            parentID: "\(key):0", windowID: "\(key):0"
        )
        let window = AXNode(
            id: "\(key):0", role: "AXWindow", title: "w",
            frame: CGRect(x: -1280, y: 0, width: 1280, height: 1440),
            parentID: "\(key):root", windowID: "\(key):0",
            children: [button]
        )
        let snapshot = AXAppSnapshot(
            appKey: key, pid: 9, nodes: [
                AXNode(id: "\(key):root", role: nil, frame: nil, parentID: nil, windowID: nil, children: [window]),
            ],
            visited: 0, truncated: false, error: nil, elapsed: 0
        )

        let out = Pipeline(screen: multiScreen).process(snapshot)
        guard let btn = out.entities.first(where: { $0.id == "\(key):0-0" }),
              let win = out.entities.first(where: { $0.id == "\(key):0" }) else {
            return XCTFail("entities missing")
        }

        // displayID is metadata; geometry follows the original main-screen formulas.
        XCTAssertEqual(btn.displayID, 2)
        XCTAssertEqual(btn.geometry.screen.x, -1000.0 / 3440.0, accuracy: 1e-6)
        XCTAssertEqual(btn.geometry.screen.y, 200.0 / 1440.0, accuracy: 1e-6)
        XCTAssertEqual(win.displayID, 2)
        // Window space stays window-relative regardless of display.
        XCTAssertEqual(btn.geometry.window.x, 0.21875, accuracy: 1e-6)
    }

    func testScreenInfoBackwardCompatibleDecode() {
        // Frames produced before V1.6 lack the displays key.
        let old = #"{"width":3440,"height":1440,"scaleFactor":1}"#
        let decoded = try! JSONDecoder.gvgl.decode(ScreenInfo.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.width, 3440)
        XCTAssertEqual(decoded.height, 1440)
        XCTAssertTrue(decoded.displays.isEmpty)
    }

    // MARK: - V3 role & attribute expansion

    /// V3 whitelist: text areas, pop-up buttons, tabs, list/table parts,
    /// sheets and friends all become entities now.
    func testExpandedRolesBecomeEntities() {
        let key = "pid:7"
        let roles = [
            "AXTextArea", "AXSecureTextField", "AXPopUpButton", "AXMenuButton",
            "AXDisclosureTriangle", "AXTabGroup", "AXTab", "AXToolbar",
            "AXList", "AXOutline", "AXTable", "AXRow", "AXCell",
            "AXSheet", "AXDrawer", "AXHeading", "AXProgressIndicator", "AXSplitter",
        ]
        let children: [AXNode] = roles.enumerated().map { i, role in
            AXNode(
                id: "\(key):0-\(i)", role: role,
                frame: CGRect(x: 10 + i * 30, y: 10, width: 20, height: 20),
                parentID: "\(key):0", windowID: "\(key):0"
            )
        }
        let window = AXNode(
            id: "\(key):0", role: "AXWindow", title: "w",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            parentID: "\(key):root", windowID: "\(key):0",
            children: children
        )
        let snapshot = AXAppSnapshot(
            appKey: key, pid: 7,
            nodes: [AXNode(id: "\(key):root", role: nil, frame: nil,
                           parentID: nil, windowID: nil, children: [window])],
            visited: 0, truncated: false, error: nil, elapsed: 0
        )
        let out = Pipeline(screen: screen).process(snapshot)
        let byRole = Dictionary(grouping: out.entities, by: \.role)
        for role in roles {
            XCTAssertEqual(byRole[role]?.count, 1, "\(role) must become an entity")
        }
    }

    /// V3 state attributes flow from snapshot node to entity.
    func testValueAndStateAttributesFlowToEntity() {
        let key = "pid:8"
        let field = AXNode(
            id: "\(key):0-0", role: "AXTextField",
            value: "kelthas@example.com", subrole: "AXSearchField",
            focused: true, placeholder: "邮箱",
            frame: CGRect(x: 10, y: 10, width: 200, height: 24),
            parentID: "\(key):0", windowID: "\(key):0"
        )
        let tab = AXNode(
            id: "\(key):0-1", role: "AXTab", title: "设置", selected: true,
            frame: CGRect(x: 10, y: 50, width: 80, height: 24),
            parentID: "\(key):0", windowID: "\(key):0"
        )
        let window = AXNode(
            id: "\(key):0", role: "AXWindow", title: "w",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            parentID: "\(key):root", windowID: "\(key):0",
            children: [field, tab]
        )
        let snapshot = AXAppSnapshot(
            appKey: key, pid: 8,
            nodes: [AXNode(id: "\(key):root", role: nil, frame: nil,
                           parentID: nil, windowID: nil, children: [window])],
            visited: 0, truncated: false, error: nil, elapsed: 0
        )
        let out = Pipeline(screen: screen).process(snapshot)
        let byID = Dictionary(uniqueKeysWithValues: out.entities.map { ($0.id, $0) })

        let f = byID["\(key):0-0"]
        XCTAssertEqual(f?.value, "kelthas@example.com")
        XCTAssertEqual(f?.subrole, "AXSearchField")
        XCTAssertEqual(f?.focused, true)
        XCTAssertEqual(f?.placeholder, "邮箱")

        let t = byID["\(key):0-1"]
        XCTAssertEqual(t?.selected, true)
    }

    /// StaticText & co often expose the same string as AXTitle and AXValue;
    /// the pipeline stores it once.
    func testValueDuplicatingTitleIsDropped() {
        let key = "pid:9"
        let text = AXNode(
            id: "\(key):0-0", role: "AXStaticText",
            title: "你好", value: "你好",
            frame: CGRect(x: 10, y: 10, width: 60, height: 16),
            parentID: "\(key):0", windowID: "\(key):0"
        )
        let window = AXNode(
            id: "\(key):0", role: "AXWindow", title: "w",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            parentID: "\(key):root", windowID: "\(key):0",
            children: [text]
        )
        let snapshot = AXAppSnapshot(
            appKey: key, pid: 9,
            nodes: [AXNode(id: "\(key):root", role: nil, frame: nil,
                           parentID: nil, windowID: nil, children: [window])],
            visited: 0, truncated: false, error: nil, elapsed: 0
        )
        let out = Pipeline(screen: screen).process(snapshot)
        XCTAssertEqual(out.entities.first { $0.id == "\(key):0-0" }?.value, nil)
    }

    /// AXValue coercion: strings truncate at the cap, booleans/numbers
    /// stringify, attributed strings flatten.
    func testValueStringCoercion() {
        XCTAssertEqual(Snapshotter.valueString(from: "abc" as AnyObject), "abc")
        XCTAssertEqual(Snapshotter.valueString(from: "" as AnyObject), nil)
        XCTAssertEqual(Snapshotter.valueString(from: kCFBooleanTrue), "true")
        XCTAssertEqual(Snapshotter.valueString(from: kCFBooleanFalse), "false")
        XCTAssertEqual(Snapshotter.valueString(from: NSNumber(value: 0.75)), "0.75")
        XCTAssertEqual(
            Snapshotter.valueString(from: NSAttributedString(string: "富文本")),
            "富文本"
        )
        let long = String(repeating: "x", count: 1000)
        XCTAssertEqual(Snapshotter.valueString(from: long as AnyObject)?.count, 512)
    }

    /// Frames captured before the V3 expansion lack the new keys; decoding
    /// must fall back to safe defaults.
    func testEntityBackwardCompatibleDecode() {
        let old = #"""
        {"id":"pid:1:0","role":"AXButton","title":"登录","enabled":true,
         "actions":["AXPress"],"appID":"pid:1","pid":1,
         "geometry":{"screen":{"x":0.1,"y":0.1,"w":0.05,"h":0.03},
                     "window":{"x":0.2,"y":0.2,"w":0.2,"h":0.1},
                     "local":{"x":0,"y":0,"w":1,"h":1},
                     "centerX":0.125,"centerY":0.115,"area":0.0015,
                     "aspect":1.6667,"region":"q1","region9":"leftTop"}}
        """#
        let decoded = try! JSONDecoder.gvgl.decode(Entity.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.title, "登录")
        XCTAssertNil(decoded.value)
        XCTAssertNil(decoded.subrole)
        XCTAssertFalse(decoded.focused)
        XCTAssertFalse(decoded.selected)
        XCTAssertNil(decoded.placeholder)
        XCTAssertNil(decoded.zIndex)
    }

    // MARK: - V3 menu bar & z-order

    /// The menu-bar subtree ("mb"-prefixed ids, windowless) becomes entities:
    /// bar, items, menus, menu items — with screen-space geometry only.
    func testMenuBarSubtreeBecomesEntities() {
        let key = "pid:5"
        let menuItem = AXNode(
            id: "\(key):mb-0-0-0", role: "AXMenuItem", title: "关于",
            frame: CGRect(x: 100, y: 30, width: 200, height: 22),
            parentID: "\(key):mb-0-0", windowID: nil
        )
        let menu = AXNode(
            id: "\(key):mb-0-0", role: "AXMenu", title: "文件",
            frame: CGRect(x: 90, y: 25, width: 220, height: 200),
            parentID: "\(key):mb-0", windowID: nil,
            children: [menuItem]
        )
        let barItem = AXNode(
            id: "\(key):mb-0", role: "AXMenuBarItem", title: "文件",
            frame: CGRect(x: 90, y: 0, width: 40, height: 22),
            parentID: "\(key):mb", windowID: nil,
            children: [menu]
        )
        let bar = AXNode(
            id: "\(key):mb", role: "AXMenuBar",
            frame: CGRect(x: 0, y: 0, width: 3440, height: 24),
            parentID: nil, windowID: nil,
            children: [barItem]
        )
        let window = AXNode(
            id: "\(key):0", role: "AXWindow", title: "w",
            frame: CGRect(x: 0, y: 30, width: 800, height: 600),
            parentID: "\(key):root", windowID: "\(key):0"
        )
        let snapshot = AXAppSnapshot(
            appKey: key, pid: 5,
            nodes: [AXNode(id: "\(key):root", role: nil, frame: nil,
                           parentID: nil, windowID: nil, children: [window]), bar],
            visited: 0, truncated: false, error: nil, elapsed: 0
        )
        let out = Pipeline(screen: screen).process(snapshot)
        let byID = Dictionary(uniqueKeysWithValues: out.entities.map { ($0.id, $0) })

        XCTAssertNotNil(byID["\(key):mb"], "AXMenuBar must be an entity")
        XCTAssertNotNil(byID["\(key):mb-0"], "AXMenuBarItem must be an entity")
        XCTAssertNotNil(byID["\(key):mb-0-0-0"], "AXMenuItem must be an entity")
        // Windowless: window space falls back to screen space.
        XCTAssertEqual(byID["\(key):mb-0"]?.geometry.window, byID["\(key):mb-0"]?.geometry.screen)
        // Entity ancestry flows through the subtree.
        XCTAssertEqual(byID["\(key):mb-0-0-0"]?.entityParentID, "\(key):mb-0-0")
    }

    /// Window entities pick up the global front-to-back rank of their CG
    /// window match; unmatched windows keep nil (off-screen / other Space).
    func testWindowZOrderAssignment() {
        let key = "pid:6"
        let winA = AXNode(
            id: "\(key):0", role: "AXWindow", title: "A",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            parentID: "\(key):root", windowID: "\(key):0"
        )
        let winB = AXNode(
            id: "\(key):1", role: "AXWindow", title: "B",
            frame: CGRect(x: 500, y: 0, width: 400, height: 300),
            parentID: "\(key):root", windowID: "\(key):1"
        )
        var snapshot = AXAppSnapshot(
            appKey: key, pid: 6,
            nodes: [AXNode(id: "\(key):root", role: nil, frame: nil,
                           parentID: nil, windowID: nil, children: [winA, winB])],
            visited: 0, truncated: false, error: nil, elapsed: 0
        )
        // CG list is global front-to-back; another app's window sits in front.
        snapshot.cgWindows = [
            CGWindowInfo(id: 900, name: "别的应用", bounds: CGRect(x: 900, y: 0, width: 300, height: 200), layer: 0, zIndex: 0),
            CGWindowInfo(id: 901, name: "B", bounds: CGRect(x: 500, y: 0, width: 400, height: 300), layer: 0, zIndex: 1),
            CGWindowInfo(id: 902, name: "A", bounds: CGRect(x: 0, y: 0, width: 400, height: 300), layer: 0, zIndex: 2),
        ]
        let out = Pipeline(screen: screen).process(snapshot)
        let byID = Dictionary(uniqueKeysWithValues: out.entities.map { ($0.id, $0) })
        XCTAssertEqual(byID["\(key):1"]?.zIndex, 1, "B is the frontmost window of this app")
        XCTAssertEqual(byID["\(key):0"]?.zIndex, 2)
    }

    /// cg diagnostics (counts/missing titles) stay opt-in; z-order is not
    /// affected by the flag.
    func testCGDiagnosticsGatedByFlag() {
        let key = "pid:11"
        let win = AXNode(
            id: "\(key):0", role: "AXWindow", title: "A",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            parentID: "\(key):root", windowID: "\(key):0"
        )
        func makeSnapshot(diagnostics: Bool) -> AXAppSnapshot {
            var s = AXAppSnapshot(
                appKey: key, pid: 11,
                nodes: [AXNode(id: "\(key):root", role: nil, frame: nil,
                               parentID: nil, windowID: nil, children: [win])],
                visited: 0, truncated: false, error: nil, elapsed: 0,
                cgDiagnosticsEnabled: diagnostics
            )
            s.cgWindows = [
                CGWindowInfo(id: 901, name: "A", bounds: CGRect(x: 0, y: 0, width: 400, height: 300), layer: 0, zIndex: 0),
                CGWindowInfo(id: 902, name: "幽灵窗", bounds: CGRect(x: 900, y: 900, width: 100, height: 100), layer: 0, zIndex: 1),
            ]
            return s
        }

        let off = Pipeline(screen: screen).process(makeSnapshot(diagnostics: false))
        XCTAssertEqual(off.cgWindowCount, 0, "diagnostics off → no CG stats")
        XCTAssertTrue(off.missingWindowTitles.isEmpty)
        XCTAssertEqual(off.entities.first { $0.id == "\(key):0" }?.zIndex, 0,
                       "z-order still assigned when diagnostics are off")

        let on = Pipeline(screen: screen).process(makeSnapshot(diagnostics: true))
        XCTAssertEqual(on.cgWindowCount, 2)
        XCTAssertEqual(on.axWindowCount, 1)
        XCTAssertEqual(on.missingWindowTitles, ["幽灵窗"])
    }

    /// Electron-class apps mutate their tree mid-walk often enough that the
    /// same path gets visited twice in one snapshot. uniqueKeysWithValues
    /// used to trap the whole daemon on the first occurrence.
    func testDuplicateNodeIDsDoNotTrap() {
        let key = "pid:12"
        func window(id: String, title: String) -> AXNode {
            AXNode(
                id: id, role: "AXWindow", title: title,
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                parentID: "\(key):root", windowID: id
            )
        }
        // Two distinct windows whose ids collide (path "0" reported twice).
        let snapshot = AXAppSnapshot(
            appKey: key, pid: 12,
            nodes: [AXNode(
                id: "\(key):root", role: nil, frame: nil,
                parentID: nil, windowID: nil,
                children: [window(id: "\(key):0", title: "第一份"), window(id: "\(key):0", title: "第二份")]
            )],
            visited: 3, truncated: false, error: nil, elapsed: 0
        )
        let out = Pipeline(screen: screen).process(snapshot)
        XCTAssertEqual(out.entities.filter { $0.id == "\(key):0" }.count, 1,
                       "duplicate node ids must collapse to one entity, first visit wins")
    }

    /// Secondary-display windows must still match their CG counterpart for
    /// z-order. Regression: pixelCenter used to mix main-screen normalization
    /// with the secondary display's origin+size (double offset), so every
    /// secondary-display window failed the 24px proximity test.
    func testSecondaryDisplayZOrderMatchesCG() {
        let dual = ScreenInfo(
            width: 3440, height: 1440, scaleFactor: 2.0,
            displays: [
                DisplayInfo(id: 1, x: 0, y: 0, width: 3440, height: 1440, scaleFactor: 2.0),
                DisplayInfo(id: 2, x: -1920, y: 0, width: 1920, height: 1080, scaleFactor: 2.0),
            ]
        )
        let key = "pid:13"
        // Window fully on the secondary display: pixels (-1920..-920, 100..700).
        let win = AXNode(
            id: "\(key):0", role: "AXWindow", title: "副屏窗",
            frame: CGRect(x: -1920, y: 100, width: 1000, height: 600),
            parentID: "\(key):root", windowID: "\(key):0"
        )
        var snapshot = AXAppSnapshot(
            appKey: key, pid: 13,
            nodes: [AXNode(id: "\(key):root", role: nil, frame: nil,
                           parentID: nil, windowID: nil, children: [win])],
            visited: 0, truncated: false, error: nil, elapsed: 0
        )
        snapshot.cgWindows = [
            CGWindowInfo(id: 950, name: "副屏窗", bounds: CGRect(x: -1920, y: 100, width: 1000, height: 600), layer: 0, zIndex: 0),
        ]
        let out = Pipeline(screen: dual).process(snapshot)
        XCTAssertEqual(out.entities.first { $0.id == "\(key):0" }?.zIndex, 0,
                       "secondary-display window must match its CG window (center -1420,400)")
        // displayID metadata still resolves to the physical display.
        XCTAssertEqual(out.entities.first { $0.id == "\(key):0" }?.displayID, 2)
    }
}
