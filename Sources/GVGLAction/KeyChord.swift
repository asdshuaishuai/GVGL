import CoreGraphics
import Foundation

/// A parsed keyboard chord ("cmd+shift+t", "return", "esc", "f12").
///
/// Two consumers with different failure modes: hotkeys must be exact (a wrong
/// modifier silently does something else), and text must not go through key
/// codes at all (IME, layouts, CJK). So this type only handles *named* keys and
/// single characters; arbitrary text uses `InputSynthesizer.type` instead.
public struct KeyChord: Equatable, Sendable {
    public var keyCode: CGKeyCode
    public var flags: CGEventFlags
    /// Canonical normalized form, for result payloads and logs.
    public var display: String

    public init(keyCode: CGKeyCode, flags: CGEventFlags, display: String) {
        self.keyCode = keyCode
        self.flags = flags
        self.display = display
    }

    public static func parse(_ text: String) -> KeyChord? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "+").map(String.init)
        guard let rawKey = parts.last, !rawKey.isEmpty else { return nil }

        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: return nil
            }
        }

        // Named keys first: "return" must not be read as the letters r-e-t…
        let keyName = rawKey.lowercased()
        if let code = namedKeys[keyName] {
            return KeyChord(
                keyCode: code, flags: flags,
                display: canonical(modifiers: parts.dropLast(), key: keyName)
            )
        }
        // Case matters for single characters: "A" is shift+a, "a" is just a.
        guard rawKey.count == 1, let character = rawKey.first else { return nil }
        guard let entry = characterKeys[character] else { return nil }
        var finalFlags = flags
        if entry.shifted { finalFlags.insert(.maskShift) }
        return KeyChord(
            keyCode: entry.code,
            flags: finalFlags,
            display: canonical(modifiers: parts.dropLast(), key: keyName)
        )
    }

    private static func canonical<S: Sequence>(modifiers: S, key: String) -> String where S.Element == String {
        (modifiers.map { $0 } + [key]).joined(separator: "+")
    }

    // Virtual key codes (ANSI / US layout) from Carbon's Events.h. Only the
    // keys an agent actually presses are listed; everything else should be
    // sent as text.
    private static let namedKeys: [String: CGKeyCode] = [
        "return": 36, "enter": 76, "tab": 48, "space": 49, "esc": 53, "escape": 53,
        "delete": 51, "backspace": 51, "forwarddelete": 117,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "help": 114, "capslock": 57,
    ]

    /// (key code, whether shift is part of the character itself).
    private struct CharacterKey {
        var code: CGKeyCode
        var shifted: Bool
    }

    private static let characterKeys: [Character: CharacterKey] = {
        var map: [Character: CharacterKey] = [:]
        let plain: [(Character, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
            ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
            ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22),
            ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29),
            ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37),
            ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44),
            ("n", 45), ("m", 46), (".", 47), ("`", 50),
        ]
        for (character, code) in plain {
            map[character] = CharacterKey(code: code, shifted: false)
        }
        // Shifted symbols are separate keys on a US layout: without the shift
        // flag they would type the unshifted character.
        let shifted: [(Character, CGKeyCode)] = [
            ("!", 18), ("@", 19), ("#", 20), ("$", 21), ("%", 23), ("^", 22),
            ("&", 26), ("*", 28), ("(", 25), (")", 29), ("_", 27), ("+", 24),
            ("{", 33), ("}", 30), ("|", 42), (":", 41), ("\"", 39), ("<", 43),
            (">", 47), ("?", 44), ("~", 50),
        ]
        for (character, code) in shifted {
            map[character] = CharacterKey(code: code, shifted: true)
        }
        // A capital letter is the same physical key plus shift.
        for (character, code) in plain where character.isLetter {
            map[Character(character.uppercased())] = CharacterKey(code: code, shifted: true)
        }
        return map
    }()
}
