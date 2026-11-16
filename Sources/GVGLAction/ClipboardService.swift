import AppKit
import Foundation

/// Clipboard access for text entry and reading.
///
/// Pasting is the only reliable way to enter long or non-ASCII text into apps
/// that ignore `AXValue` writes (web views above all). The user's clipboard is
/// saved and restored — an agent must not silently eat it.
public enum ClipboardService {
    public static func read() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    @discardableResult
    public static func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// Runs `body` with `text` on the clipboard, then restores what was there.
    /// The caller is responsible for waiting until the target app has read the
    /// pasteboard (a `cmd+V` needs a beat) before returning.
    public static func substituting<T>(_ text: String, _ body: () throws -> T) rethrows -> T {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        defer {
            if let previous {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
        return try body()
    }
}
