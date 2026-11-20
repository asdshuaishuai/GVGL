import Foundation

/// How the executor is allowed to touch the desktop.
///
/// The product rule is "background by default": an agent must not move the
/// user's pointer, inject keystrokes, overwrite the clipboard, or bring apps
/// to the front. Everything reachable through accessibility actions stays
/// available; anything that would enter the shared HID stream is refused with
/// `blocked_by_policy`.
///
/// This is the macOS equivalent of "run in a separate desktop": macOS has no
/// public API for a second, input-isolated GUI session, so isolation is
/// achieved by never touching the global input path at all. An app may still
/// choose to activate itself in reaction to a semantic action — that is the
/// app's behaviour, not synthesized input from us.
public enum InteractionMode: String, Codable, Sendable, CaseIterable {
    /// Accessibility semantics only. No CGEvent, no activation, no clipboard
    /// writes. Verbs that cannot work this way fail loudly instead of falling
    /// back to shared input.
    case background
    /// May synthesize pointer/keyboard events and activate apps. Only for a
    /// machine the agent owns (the pre-policy behaviour).
    case foreground

    public var allowsSyntheticInput: Bool { self == .foreground }
    public var allowsActivation: Bool { self == .foreground }
    public var allowsClipboardWrite: Bool { self == .foreground }

    // MARK: - Policy gates
    //
    // These run *before* resolution so a refused action costs neither a daemon
    // round trip nor an AX write, and so the refusal is testable without a
    // live desktop.

    public func requireSyntheticInput(_ verb: String) throws {
        guard allowsSyntheticInput else {
            throw ActionFailure(
                .blockedByPolicy,
                "\(verb) needs synthetic pointer/keyboard input, which is disabled in background mode "
                + "(no global HID events; use --mode foreground on a machine the agent owns)"
            )
        }
    }

    public func requireActivation(_ verb: String) throws {
        guard allowsActivation else {
            throw ActionFailure(
                .blockedByPolicy,
                "\(verb) would bring an app to the front, which is disabled in background mode "
                + "(use --mode foreground)"
            )
        }
    }

    public func requireClipboardWrite() throws {
        guard allowsClipboardWrite else {
            throw ActionFailure(
                .blockedByPolicy,
                "clipboard writes would overwrite the user's clipboard, which is disabled in background mode "
                + "(reads are allowed; use --mode foreground)"
            )
        }
    }
}
