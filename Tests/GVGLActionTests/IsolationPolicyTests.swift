import XCTest
@testable import GVGLAction
import GVGLCore
import GVGLQuery

/// Background isolation is a product rule, not a hint: every verb that would
/// touch the shared HID stream, activate an app, or overwrite the clipboard
/// must fail with `blocked_by_policy` — and fail before resolving a target or
/// writing anything.
final class IsolationPolicyTests: XCTestCase {
    private func makeExecutor(_ mode: InteractionMode) -> ActionExecutor {
        ActionExecutor(
            options: ExecutorOptions(socketPath: "/tmp/gvgl-isolation-tests.sock"),
            mode: mode
        )
    }

    private func blocked(_ body: () throws -> Void, file: StaticString = #filePath,
                         line: UInt = #line) -> ActionFailure? {
        do {
            try body()
            XCTFail("expected blocked_by_policy", file: file, line: line)
            return nil
        } catch let failure as ActionFailure {
            XCTAssertEqual(failure.error.code, .blockedByPolicy, failure.error.message,
                           file: file, line: line)
            return failure
        } catch {
            XCTFail("expected ActionFailure.blocked_by_policy, got \(error)", file: file, line: line)
            return nil
        }
    }

    func testDefaultModeIsBackground() {
        XCTAssertEqual(makeExecutor(.background).mode, .background)
        // Constructing an executor without naming a mode must pick the safe one.
        let executor = ActionExecutor(options: ExecutorOptions(socketPath: "/tmp/x.sock"))
        XCTAssertEqual(executor.mode, .background)
    }

    func testBackgroundForbidsEverySharedDesktopCapability() {
        XCTAssertFalse(InteractionMode.background.allowsSyntheticInput)
        XCTAssertFalse(InteractionMode.background.allowsActivation)
        XCTAssertFalse(InteractionMode.background.allowsClipboardWrite)
        XCTAssertTrue(InteractionMode.foreground.allowsSyntheticInput)
        XCTAssertTrue(InteractionMode.foreground.allowsActivation)
        XCTAssertTrue(InteractionMode.foreground.allowsClipboardWrite)
    }

    func testHoverNeedsSyntheticPointer() {
        let failure = blocked {
            _ = try makeExecutor(.background).hover(.query(QueryParams(role: "AXButton")))
        }
        XCTAssertTrue(failure?.error.message.contains("hover") == true)
    }

    func testDragNeedsSyntheticPointer() {
        blocked {
            _ = try makeExecutor(.background).drag(
                from: .query(QueryParams(role: "AXButton")),
                to: .query(QueryParams(role: "AXButton"))
            )
        }
    }

    func testKeyChordNeedsSyntheticKeyboard() {
        let failure = blocked {
            _ = try makeExecutor(.background).sendKey("cmd+s")
        }
        XCTAssertTrue(failure?.error.message.contains("key") == true)
    }

    func testTypingFallbacksAreRefusedButSetValueIsAllowed() {
        blocked {
            _ = try makeExecutor(.background).type(
                .query(QueryParams(role: "AXTextField")), text: "hello", method: .keys
            )
        }
        blocked {
            _ = try makeExecutor(.background).type(
                .query(QueryParams(role: "AXTextField")), text: "hello", method: .paste
            )
        }
        // auto is fine at the policy stage: it resolves to AXValue when the
        // field supports it, and refuses later when it does not.
        do {
            _ = try makeExecutor(.background).type(
                .query(QueryParams(role: "AXTextField")), text: "hello", method: .auto
            )
            XCTFail("no daemon should be reachable")
        } catch let failure as ActionFailure {
            XCTAssertNotEqual(failure.error.code, .blockedByPolicy, failure.error.message)
        } catch {
            // Connection/trust failure is the expected path; policy allowed it.
        }
    }

    func testSubmitIsRefusedBeforeWritingAnything() {
        blocked {
            _ = try makeExecutor(.background).type(
                .query(QueryParams(role: "AXTextField")), text: "hello", submit: true
            )
        }
    }

    func testClipboardWritesAreRefusedReadsAreNot() {
        _ = blocked {
            _ = try makeExecutor(.background).clipboardAction("set", text: "stolen")
        }
        // Reads are harmless and must keep working without a daemon.
        let read = try? makeExecutor(.background).clipboardAction("get", text: nil)
        XCTAssertEqual(read?.ok, true)
    }

    func testAppActivationIsRefusedBeforePermissionChecks() {
        let failure = blocked {
            _ = try makeExecutor(.background).appAction("activate", target: "Finder")
        }
        XCTAssertTrue(failure?.error.message.contains("activate") == true)
    }

    func testForegroundModeDoesNotRefuseAtThePolicyStage() {
        do {
            _ = try makeExecutor(.foreground).hover(.query(QueryParams(role: "AXButton")))
            XCTFail("no desktop should be reachable from a unit test")
        } catch let failure as ActionFailure {
            XCTAssertNotEqual(failure.error.code, .blockedByPolicy, failure.error.message)
        } catch {
            // Connection/trust failure proves the policy gate was passed.
        }
    }

    func testResultCarriesTheIsolationItRanUnder() throws {
        var result = ActionResult(action: "press")
        XCTAssertNil(result.isolation, "unset results must not claim a mode")
        result.isolation = .background
        let data = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["isolation"] as? String, "background")
    }
}
