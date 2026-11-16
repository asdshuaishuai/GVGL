import Foundation

/// AXValue arrives in many shapes (String / NSNumber / CFBoolean /
/// NSAttributedString / AXValue). One coercion, shared by the snapshotter
/// (perception) and the action layer (verification) — a text field must not
/// mean one thing when it is captured and another when it is read back after
/// typing, or "typed successfully" becomes unverifiable.
public enum AXValueCoercion {
    /// Coerces to a short display string and caps it: terminal scrollbacks and
    /// document text areas can otherwise pump megabytes into every frame.
    public static func string(from value: AnyObject, cap: Int = 512) -> String? {
        // CFBoolean must be tested before NSNumber (it bridges as NSNumber).
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return (value as! Bool) ? "true" : "false"
        }
        if let string = value as? String {
            return string.isEmpty ? nil : String(string.prefix(cap))
        }
        if let attributed = value as? NSAttributedString {
            let string = attributed.string
            return string.isEmpty ? nil : String(string.prefix(cap))
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
