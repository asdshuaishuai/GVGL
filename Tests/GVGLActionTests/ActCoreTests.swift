import XCTest
@testable import GVGLAction
import GVGLCore

final class ElementPathTests: XCTestCase {
    func testParsesApplicationRoot() {
        let path = ElementPath.parse("pid:722:root")
        XCTAssertEqual(path?.appKey, "pid:722")
        XCTAssertEqual(path?.root, .application)
        XCTAssertEqual(path?.indices, [])
        XCTAssertEqual(path?.pid, 722)
        XCTAssertEqual(path?.id, "pid:722:root")
    }

    func testParsesNumericPath() {
        let path = ElementPath.parse("pid:7:0-2-13")
        XCTAssertEqual(path?.root, .application)
        XCTAssertEqual(path?.indices, [0, 2, 13])
        XCTAssertEqual(path?.id, "pid:7:0-2-13")
    }

    func testParsesMenuBarRootAndPath() {
        XCTAssertEqual(ElementPath.parse("pid:9:mb")?.root, .menuBar)
        XCTAssertEqual(ElementPath.parse("pid:9:mb")?.indices, [])
        XCTAssertEqual(ElementPath.parse("pid:9:mb-1-0")?.indices, [1, 0])
        XCTAssertEqual(ElementPath.parse("pid:9:mb-1-0")?.id, "pid:9:mb-1-0")
    }

    func testRejectsNonPaths() {
        XCTAssertNil(ElementPath.parse(""))
        XCTAssertNil(ElementPath.parse("pid:7"))
        XCTAssertNil(ElementPath.parse("pid:7:"))
        XCTAssertNil(ElementPath.parse("pid:7:0-x"))
        XCTAssertNil(ElementPath.parse("pid:7:0--1"))
        XCTAssertNil(ElementPath.parse("heuristic-id"))
    }

    func testAncestryIsPrefixBased() {
        let window = ElementPath.parse("pid:7:0-2")!
        let child = ElementPath.parse("pid:7:0-2-3-1")!
        let other = ElementPath.parse("pid:7:0-3")!
        XCTAssertTrue(window.isAncestor(of: child))
        XCTAssertTrue(window.isAncestor(of: window))
        XCTAssertFalse(window.isAncestor(of: other))
    }
}

final class KeyChordTests: XCTestCase {
    func testModifiedLetter() {
        let chord = KeyChord.parse("cmd+shift+t")
        XCTAssertEqual(chord?.keyCode, 17)
        XCTAssertEqual(chord?.flags.contains(.maskCommand), true)
        XCTAssertEqual(chord?.flags.contains(.maskShift), true)
    }

    func testNamedKeys() {
        XCTAssertEqual(KeyChord.parse("return")?.keyCode, 36)
        XCTAssertEqual(KeyChord.parse("esc")?.keyCode, 53)
        XCTAssertEqual(KeyChord.parse("f12")?.keyCode, 111)
        XCTAssertEqual(KeyChord.parse("cmd+return")?.flags.contains(.maskCommand), true)
    }

    func testShiftIsInferredForUppercaseAndSymbols() {
        XCTAssertEqual(KeyChord.parse("A")?.keyCode, 0)
        XCTAssertEqual(KeyChord.parse("A")?.flags.contains(.maskShift), true)
        XCTAssertEqual(KeyChord.parse("!")?.keyCode, 18)
        XCTAssertEqual(KeyChord.parse("!")?.flags.contains(.maskShift), true)
    }

    func testRejectsGarbage() {
        XCTAssertNil(KeyChord.parse(""))
        XCTAssertNil(KeyChord.parse("hyper+x"))
        XCTAssertNil(KeyChord.parse("cmd+"))
        XCTAssertNil(KeyChord.parse("cmd+ab"))
    }
}

final class JSONValueTests: XCTestCase {
    func testRoundTripsMixedJSON() throws {
        let source = #"{"ok":true,"n":3,"s":"x","a":[1,null],"o":{"k":"v"}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
        XCTAssertEqual(decoded, value)
    }

    func testNullRoundTrip() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("null".utf8))
        XCTAssertEqual(value, .null)
    }
}

final class ActionResultTests: XCTestCase {
    func testFailureEncodesStableCode() throws {
        let result = ActionResult.failure("press", ActionError(.staleReference, "moved"), latencyMS: 4)
        let data = try JSONEncoder().encode(result)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"ok\":false"))
        XCTAssertTrue(text.contains("\"code\":\"stale_reference\""))
        XCTAssertTrue(text.contains("\"latencyMS\":4"))
    }

    func testErrorCodesAreSnakeCase() {
        XCTAssertEqual(ActionErrorCode.targetObscured.rawValue, "target_obscured")
        XCTAssertEqual(ActionErrorCode.ambiguousMatch.rawValue, "ambiguous_match")
        XCTAssertEqual(ActionErrorCode.focusFailed.rawValue, "focus_failed")
    }
}

/// The no-screenshot reader must use the same label sources the AX tree
/// actually provides. SwiftUI exposes button labels as AXDescription (stored
/// in `detail`), not AXTitle — skipping `detail` made transcripts of SwiftUI
/// windows label-less.
final class TranscriptTextTests: XCTestCase {
    private func entity(title: String? = nil, value: String? = nil,
                        placeholder: String? = nil, detail: String? = nil) -> Entity {
        Entity(
            id: "pid:1:0-1", role: "AXButton", title: title, detail: detail,
            identifier: nil, value: value, placeholder: placeholder,
            enabled: true, actions: ["AXPress"],
            axParentID: nil, entityParentID: nil, windowID: nil,
            appID: "pid:1", pid: 1,
            geometry: Geometry(screen: .unit, window: .unit)
        )
    }

    func testDescriptionIsUsedWhenTitleIsEmpty() {
        XCTAssertEqual(
            ActionExecutor.transcriptText(for: entity(detail: "读窗口文本")),
            "读窗口文本"
        )
    }

    func testTitleStillWinsOverDescription() {
        XCTAssertEqual(
            ActionExecutor.transcriptText(for: entity(title: "登录", detail: "描述")),
            "登录"
        )
    }

    func testWhitespaceOnlyTextIsIgnored() {
        XCTAssertNil(ActionExecutor.transcriptText(for: entity(detail: "   ")))
    }

    /// A checkbox's value is its state, not its name: "允许执行动作: 0", never a
    /// bare "0" (which is what a value-first fallback produced).
    func testControlStateIsAppendedToItsLabel() {
        XCTAssertEqual(
            ActionExecutor.transcriptText(for: entity(value: "0", detail: "允许执行动作")),
            "允许执行动作: 0"
        )
    }

    /// A text field's label and content are both useful.
    func testTextFieldShowsLabelAndContent() {
        XCTAssertEqual(
            ActionExecutor.transcriptText(for: entity(value: "/tmp/gvgl.sock", detail: "socket 路径")),
            "socket 路径: /tmp/gvgl.sock"
        )
    }
}
