import CoreGraphics
import Foundation

/// Synthetic input events (mouse, keyboard, scroll, drag).
///
/// Everything here is a *device-level* event posted into the HID stream — the
/// same path a human's input takes — so apps that ignore accessibility actions
/// still respond. This is the coordinate fallback; the preferred path for
/// controls that expose them is AX actions (`ActionExecutor.press`).
///
/// No screenshot, no window-image, no OCR: coordinates come from AX geometry
/// and are hit-tested before anything is clicked (see `ClickGuard`).
public enum InputSynthesizer {
    private static let source = CGEventSource(stateID: .hidSystemState)

    public enum MouseButton: String, Sendable {
        case left, right, middle

        var cgButton: CGMouseButton {
            switch self {
            case .left: return .left
            case .right: return .right
            case .middle: return .center
            }
        }

        var downType: CGEventType {
            switch self {
            case .left: return .leftMouseDown
            case .right: return .rightMouseDown
            case .middle: return .otherMouseDown
            }
        }

        var upType: CGEventType {
            switch self {
            case .left: return .leftMouseUp
            case .right: return .rightMouseUp
            case .middle: return .otherMouseUp
            }
        }
    }

    // MARK: - Mouse

    public static func move(to point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left
        ) else { return }
        event.post(tap: .cghidEventTap)
        settle(0.01)
    }

    /// A real down/up at `point`. `count > 1` sets the click-state field on
    /// each pair, which is what turns two clicks into a double-click for apps
    /// that inspect click counts instead of timing.
    public static func click(at point: CGPoint, button: MouseButton = .left, count: Int = 1) {
        move(to: point)
        let clicks = max(1, count)
        for index in 1...clicks {
            guard let down = CGEvent(
                mouseEventSource: source, mouseType: button.downType,
                mouseCursorPosition: point, mouseButton: button.cgButton
            ), let up = CGEvent(
                mouseEventSource: source, mouseType: button.upType,
                mouseCursorPosition: point, mouseButton: button.cgButton
            ) else { return }
            if clicks > 1 {
                down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
                up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            }
            down.post(tap: .cghidEventTap)
            settle(0.02)
            up.post(tap: .cghidEventTap)
            if clicks > 1 { settle(0.06) }
        }
    }

    public static func drag(from start: CGPoint, to end: CGPoint, steps: Int = 20) {
        move(to: start)
        guard let down = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: start, mouseButton: .left
        ) else { return }
        down.post(tap: .cghidEventTap)
        settle(0.05)

        let count = max(1, steps)
        for step in 1...count {
            let t = Double(step) / Double(count)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            guard let move = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseDragged,
                mouseCursorPosition: point, mouseButton: .left
            ) else { break }
            move.post(tap: .cghidEventTap)
            settle(0.012)
        }

        guard let up = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseUp,
            mouseCursorPosition: end, mouseButton: .left
        ) else { return }
        up.post(tap: .cghidEventTap)
    }

    /// Posts a wheel event at `point`. Scroll goes to the window under the
    /// pointer on macOS, so the cursor is moved first — otherwise the event
    /// lands wherever the user last left the mouse.
    ///
    /// `vertical < 0` scrolls content up (toward the end of the document),
    /// matching the sign convention of CGEvent's wheel1.
    public static func scroll(at point: CGPoint, vertical: Int32, horizontal: Int32 = 0) {
        move(to: point)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source, units: .line,
            wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    /// Types arbitrary text without key codes: Unicode keyboard events carry
    /// the characters themselves, so layouts, IMEs and CJK work.
    ///
    /// Chunked because some apps (and the IME layer) truncate long Unicode
    /// payloads; 20 UTF-16 units stays well inside what the system delivers in
    /// one event. Chunks never split a surrogate pair.
    public static func type(_ text: String) {
        for chunk in chunks(of: text, maxUTF16: 20) {
            let units = Array(chunk.utf16)
            guard !units.isEmpty, let down = CGEvent(
                keyboardEventSource: source, virtualKey: 0, keyDown: true
            ), let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap)
            settle(0.004)
            up.post(tap: .cghidEventTap)
            settle(0.006)
        }
    }

    public static func press(_ chord: KeyChord) {
        let modifierCodes: [(CGEventFlags, CGKeyCode)] = [
            (.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58),
            (.maskControl, 59), (.maskSecondaryFn, 63),
        ]
        let active = modifierCodes.filter { chord.flags.contains($0.0) }

        for (_, code) in active {
            postKey(code, down: true, flags: chord.flags)
        }
        postKey(chord.keyCode, down: true, flags: chord.flags)
        postKey(chord.keyCode, down: false, flags: chord.flags)
        for (_, code) in active.reversed() {
            postKey(code, down: false, flags: chord.flags)
        }
    }

    private static func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            return
        }
        if !flags.isEmpty { event.flags = flags }
        event.post(tap: .cghidEventTap)
        settle(0.008)
    }

    // MARK: - Helpers

    private static func chunks(of text: String, maxUTF16: Int) -> [String] {
        var result: [String] = []
        var current = ""
        var size = 0
        for character in text {
            let width = String(character).utf16.count
            if size + width > maxUTF16, !current.isEmpty {
                result.append(current)
                current = ""
                size = 0
            }
            current.append(character)
            size += width
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
