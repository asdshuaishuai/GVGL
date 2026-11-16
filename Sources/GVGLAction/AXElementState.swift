import ApplicationServices
import CoreGraphics
import Foundation
import GVGLCore

/// Pixel rect in Quartz global coordinates (top-left origin), the same space
/// AX and CGWindow use. Serialized as an array-friendly object so JSON output
/// stays self-describing.
public struct PixelRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.w = Double(rect.size.width)
        self.h = Double(rect.size.height)
    }
}

/// Live state of one AX element, read on demand.
///
/// This is the action layer's ground truth: actions are addressed by entity id
/// (from a frame that may be tens of milliseconds old), but clicks and
/// keystrokes must use the element's *current* geometry, and verification must
/// read its *current* value. Reading through the daemon would couple action
/// accuracy to the debounce/capture pipeline; reading AX directly keeps the
/// action loop independent of the model's refresh cadence.
public struct AXElementState: Sendable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var identifier: String?
    public var value: String?
    public var focused: Bool
    public var enabled: Bool
    public var actions: [String]
    public var position: CGPoint?
    public var size: CGSize?
    /// Whether `AXValue` can be written (the cheapest way to type into a field).
    public var valueSettable: Bool
    /// Whether `AXFocused` can be written (needed before synthetic keystrokes).
    public var focusedSettable: Bool

    public var frame: CGRect? {
        guard let position, let size, size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    public var center: CGPoint? {
        guard let frame else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    public var isSecureTextField: Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    public static func read(_ element: AXUIElement, valueCap: Int = 512) -> AXElementState {
        let role = stringAttribute(element, kAXRoleAttribute)
        let valueRef = attribute(element, kAXValueAttribute)
        let position = pointAttribute(element, kAXPositionAttribute)
        let size = sizeAttribute(element, kAXSizeAttribute)
        return AXElementState(
            role: role,
            subrole: stringAttribute(element, kAXSubroleAttribute),
            title: stringAttribute(element, kAXTitleAttribute),
            identifier: stringAttribute(element, kAXIdentifierAttribute),
            value: valueRef.flatMap { AXValueCoercion.string(from: $0, cap: valueCap) },
            focused: boolAttribute(element, kAXFocusedAttribute) ?? false,
            enabled: boolAttribute(element, kAXEnabledAttribute) ?? true,
            actions: actionNames(element),
            position: position,
            size: size,
            valueSettable: isSettable(element, kAXValueAttribute),
            focusedSettable: isSettable(element, kAXFocusedAttribute)
        )
    }

    /// Full (uncapped by frame budget) value read for "show me this field's
    /// text" requests. Separate from `read` because frames must stay small.
    public static func fullValue(_ element: AXUIElement, cap: Int = 8000) -> String? {
        guard let ref = attribute(element, kAXValueAttribute) else { return nil }
        return AXValueCoercion.string(from: ref, cap: cap)
    }

    /// Whether the live element is still the entity the caller meant.
    ///
    /// Role is a hard gate (an id that now resolves to a different kind of
    /// element is stale by definition). Identifier is the strongest textual
    /// identity. Titles are deliberately NOT a hard gate when geometry is
    /// available: apps legitimately rewrite button titles ("Cancel" → "停止"),
    /// and refusing those would turn a working action into a false stale error.
    /// Position is the tiebreaker, in normalized main-display space so the same
    /// rule works on every display.
    public func matches(_ entity: Entity, screen: ScreenInfo? = nil,
                        tolerance: Double = 0.03) -> Bool {
        if let role, !role.isEmpty, role != entity.role { return false }
        if let expected = entity.identifier, !expected.isEmpty,
           let actual = identifier, !actual.isEmpty, actual != expected {
            return false
        }
        if let screen, let center {
            let expectedX = entity.geometry.centerX * screen.width
            let expectedY = entity.geometry.centerY * screen.height
            let dx = (center.x - expectedX) / max(screen.width, 1)
            let dy = (center.y - expectedY) / max(screen.height, 1)
            if (dx * dx + dy * dy).squareRoot() > tolerance { return false }
        } else if let expected = entity.title, !expected.isEmpty,
                  let title, !title.isEmpty, title != expected {
            return false
        }
        return true
    }

    public var snapshot: ElementSnapshot {
        ElementSnapshot(state: self)
    }

    // MARK: - Attribute helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else {
            return nil
        }
        return ref
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    private static func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let ref = attribute(element, name), CFGetTypeID(ref) == AXValueGetTypeID() else {
            return nil
        }
        let ax = unsafeBitCast(ref, to: AXValue.self)
        guard AXValueGetType(ax) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ax, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let ref = attribute(element, name), CFGetTypeID(ref) == AXValueGetTypeID() else {
            return nil
        }
        let ax = unsafeBitCast(ref, to: AXValue.self)
        guard AXValueGetType(ax) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ax, .cgSize, &size) else { return nil }
        return size
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }
}

/// Codable projection used in action results and CLI output.
public struct ElementSnapshot: Codable, Hashable, Sendable {
    public var exists: Bool
    public var id: String?
    public var role: String?
    public var title: String?
    public var value: String?
    public var focused: Bool
    public var enabled: Bool
    public var actions: [String]
    public var frame: PixelRect?

    public init(exists: Bool, id: String? = nil, role: String? = nil, title: String? = nil,
                value: String? = nil, focused: Bool = false, enabled: Bool = true,
                actions: [String] = [], frame: PixelRect? = nil) {
        self.exists = exists
        self.id = id
        self.role = role
        self.title = title
        self.value = value
        self.focused = focused
        self.enabled = enabled
        self.actions = actions
        self.frame = frame
    }

    public init(state: AXElementState, id: String? = nil) {
        self.init(
            exists: true,
            id: id,
            role: state.role,
            title: state.title,
            value: state.value,
            focused: state.focused,
            enabled: state.enabled,
            actions: state.actions,
            frame: state.frame.map(PixelRect.init)
        )
    }

    public static let missing = ElementSnapshot(exists: false)
}
