import ApplicationServices
import Foundation

public enum AXResolveError: Error, CustomStringConvertible, Equatable {
    case invalidID(String)
    case wrongProcess(id: String, expected: Int32)
    case menuBarMissing
    case elementMissing(path: String, index: Int, available: Int)

    public var description: String {
        switch self {
        case .invalidID(let id):
            return "not an element id (expected pid:NNN:0-2-3, pid:NNN:root or pid:NNN:mb-…): \(id)"
        case .wrongProcess(let id, let expected):
            return "element id \(id) belongs to another process (target pid \(expected))"
        case .menuBarMissing:
            return "the application exposes no AXMenuBar subtree"
        case .elementMissing(let path, let index, let available):
            return "element path \(path) no longer resolves: child \(index) missing (\(available) children)"
        }
    }
}

/// Turns an entity id back into a live AXUIElement.
///
/// Resolution is deliberately *path-based*, mirroring the snapshotter: the id
/// is the address, and any tree shift invalidates it. Callers must therefore
/// validate the resolved element against the entity they expected
/// (`AXElementState.matches`) and re-locate on mismatch — see `ActionExecutor`.
public struct AXResolver: Sendable {
    public let pid: Int32

    public init(pid: Int32) {
        self.pid = pid
    }

    /// A fresh application element. Each caller gets its own proxy so a
    /// per-call messaging timeout can't leak into unrelated reads.
    public func application() -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        // Actions are latency-critical: a wedged app must fail fast instead of
        // hanging the caller for the default multi-second messaging timeout.
        AXUIElementSetMessagingTimeout(app, 0.35)
        return app
    }

    public func resolve(_ id: String) throws -> AXUIElement {
        guard let path = ElementPath.parse(id) else { throw AXResolveError.invalidID(id) }
        guard let pathPID = path.pid, pathPID == pid else {
            throw AXResolveError.wrongProcess(id: id, expected: pid)
        }
        return try resolve(path)
    }

    public func resolve(_ path: ElementPath) throws -> AXUIElement {
        let app = application()
        var current: AXUIElement
        switch path.root {
        case .application:
            current = app
        case .menuBar:
            guard let menuBar = Self.menuBar(of: app) else { throw AXResolveError.menuBarMissing }
            current = menuBar
        }

        for index in path.indices {
            let children = Self.children(of: current)
            guard index >= 0, index < children.count else {
                throw AXResolveError.elementMissing(
                    path: path.id, index: index, available: children.count
                )
            }
            current = children[index]
        }
        return current
    }

    // MARK: - Attribute plumbing

    public static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == CFArrayGetTypeID() else { return [] }
        let array = ref as! [AnyObject]
        return array.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    public static func menuBar(of app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    public static func role(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    /// Title only — cheap enough for menu-tree scans, where reading the full
    /// state (actions, settable flags, value) per candidate would be wasteful.
    public static func title(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    public static func parent(of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }
}
