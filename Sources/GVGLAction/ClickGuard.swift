import ApplicationServices
import Foundation

/// Refuses to click a point when the element under it is not the intended
/// target.
///
/// This is the safety mechanism that makes coordinate clicking defensible
/// without screenshots: `AXUIElementCopyElementAtPosition` answers "what is
/// actually at this pixel" from the accessibility tree, so an overlay, a sheet
/// that just appeared, or a window that moved between capture and click turns
/// into a refusal instead of a stray click on the user's work.
public enum ClickGuard {
    public enum Outcome: Sendable, Equatable {
        case clear
        case obscured(hitRole: String?, hitTitle: String?)
        /// The app answered no hit-test (some non-native surfaces). Callers
        /// decide whether that is acceptable; the executor refuses by default.
        case unavailable
    }

    /// Container roles legitimately "contain" the point without being the hit
    /// target: clicking a window's centre hits its content view, not the
    /// window, and that is correct.
    private static let containerRoles: Set<String> = [
        "AXWindow", "AXSheet", "AXDrawer", "AXGroup", "AXScrollArea",
        "AXSplitGroup", "AXLayoutArea", "AXList", "AXOutline", "AXTable",
    ]

    public static func check(target: AXUIElement, app: AXUIElement, at point: CGPoint) -> Outcome {
        var hitRef: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hitRef)
        guard error == .success, let hit = hitRef else { return .unavailable }

        if CFEqual(hit, target) { return .clear }
        // A child of the target (a button's title text, a field's value area)
        // is the target for hit-testing purposes.
        if isDescendant(hit, of: target) { return .clear }
        // For container targets, an ancestor hit is fine: the point is inside
        // the container and the container itself is not clickable.
        if let role = AXResolver.role(of: target), containerRoles.contains(role),
           isDescendant(target, of: hit) {
            return .clear
        }
        return .obscured(
            hitRole: AXResolver.role(of: hit),
            hitTitle: stringAttribute(hit, kAXTitleAttribute)
        )
    }

    /// Walks AXParent upward. Bounded like every other ancestor walk in this
    /// codebase: a malformed tree must not hang an action.
    static func isDescendant(_ child: AXUIElement, of ancestor: AXUIElement, maxHops: Int = 64) -> Bool {
        var current: AXUIElement? = child
        var hops = 0
        while let element = current, hops < maxHops {
            if CFEqual(element, ancestor) { return true }
            current = AXResolver.parent(of: element)
            hops += 1
        }
        return false
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }
}
