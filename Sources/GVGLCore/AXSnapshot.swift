import ApplicationServices
import Foundation

/// Raw snapshot node mirroring the AX tree (pre-normalization).
public struct AXNode: Hashable, Sendable {
    public var id: String
    public var role: String?
    public var title: String?
    public var detail: String?
    public var identifier: String?
    /// AXValue coerced to a short string (see Snapshotter.valueString).
    public var value: String?
    public var subrole: String?
    public var focused: Bool
    public var selected: Bool
    public var placeholder: String?
    public var enabled: Bool
    public var actions: [String]
    /// Quartz pixel rect (top-left origin), if the element exposes position/size.
    public var frame: CGRect?
    public var parentID: String?
    public var windowID: String?
    public var children: [AXNode] = []
    public var truncated: Bool = false

    public init(
        id: String,
        role: String? = nil,
        title: String? = nil,
        detail: String? = nil,
        identifier: String? = nil,
        value: String? = nil,
        subrole: String? = nil,
        focused: Bool = false,
        selected: Bool = false,
        placeholder: String? = nil,
        enabled: Bool = true,
        actions: [String] = [],
        frame: CGRect? = nil,
        parentID: String? = nil,
        windowID: String? = nil,
        children: [AXNode] = [],
        truncated: Bool = false
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.detail = detail
        self.identifier = identifier
        self.value = value
        self.subrole = subrole
        self.focused = focused
        self.selected = selected
        self.placeholder = placeholder
        self.enabled = enabled
        self.actions = actions
        self.frame = frame
        self.parentID = parentID
        self.windowID = windowID
        self.children = children
        self.truncated = truncated
    }
}

public struct SnapshotConfig: Sendable {
    public var nodeBudget: Int
    public var depthLimit: Int
    public var messagingTimeout: CFTimeInterval
    public var includeActions: Bool
    /// Hard wall-clock cap: traversal stops once exceeded (guards against
    /// unresponsive apps that stall every AX call until the messaging timeout).
    public var maxCaptureTime: TimeInterval
    /// V2-3 CGWindow cross-check. OFF by default: the original doc mandates a
    /// single AX data source for V1. Enable with --cg-check for diagnostics.
    public var cgProbeEnabled: Bool

    public init(
        nodeBudget: Int = 3000,
        depthLimit: Int = 64,
        messagingTimeout: CFTimeInterval = 0.4,
        includeActions: Bool = true,
        maxCaptureTime: TimeInterval = 1.0,
        cgProbeEnabled: Bool = false
    ) {
        self.nodeBudget = nodeBudget
        self.depthLimit = depthLimit
        self.messagingTimeout = messagingTimeout
        self.includeActions = includeActions
        self.maxCaptureTime = maxCaptureTime
        self.cgProbeEnabled = cgProbeEnabled
    }
}

public enum AXSnapshotError: String, Sendable {
    case permissionDenied
    case apiDisabled
    case failedToCreate
    case noWindows
    case axError
}

public struct AXAppSnapshot: Sendable {
    public var appKey: String
    public var pid: Int32
    /// Owning application display name (filled by the engine; flows into
    /// every entity so frames carry the app title).
    public var appName: String?
    public var nodes: [AXNode]
    public var visited: Int
    /// How many times the AX action call ERRORED (as opposed to legitimately
    /// reporting no actions). Non-zero means the `actions` field in this
    /// snapshot is incomplete for an unknown reason — previously such errors
    /// collapsed into an empty array and were indistinguishable from "this
    /// element has no actions", which is how a broken field stays invisible.
    public var actionProbeFailures: Int
    public var truncated: Bool
    public var error: AXSnapshotError?
    public var elapsed: TimeInterval
    /// On-screen CG windows of the same pid (always collected: cheap local
    /// call; drives window z-order ranks and, when enabled, diagnostics).
    public var cgWindows: [CGWindowInfo]
    /// --cg-check: expose cgWindowCount/missingWindowTitles diagnostics in the
    /// frame meta. Z-order ranking is always on regardless of this flag.
    public var cgDiagnosticsEnabled: Bool

    public init(
        appKey: String,
        pid: Int32,
        nodes: [AXNode],
        visited: Int,
        actionProbeFailures: Int = 0,
        truncated: Bool,
        error: AXSnapshotError?,
        elapsed: TimeInterval,
        cgWindows: [CGWindowInfo] = [],
        cgDiagnosticsEnabled: Bool = false,
        appName: String? = nil
    ) {
        self.appKey = appKey
        self.pid = pid
        self.appName = appName
        self.nodes = nodes
        self.visited = visited
        self.actionProbeFailures = actionProbeFailures
        self.truncated = truncated
        self.error = error
        self.elapsed = elapsed
        self.cgWindows = cgWindows
        self.cgDiagnosticsEnabled = cgDiagnosticsEnabled
    }
}

/// DFS traversal of one app's AX tree, reading attributes in batches.
public final class Snapshotter: @unchecked Sendable {
    public var config: SnapshotConfig
    /// Second data source for window-level cross-validation (V2-3).
    public var cgProvider: CGWindowProviding

    public init(config: SnapshotConfig = SnapshotConfig(), cgProvider: CGWindowProviding = CGWindowProbe()) {
        self.config = config
        self.cgProvider = cgProvider
    }

    public func snapshot(pid: Int32, appKey: String) -> AXAppSnapshot {
        let start = Date()
        guard AXIsProcessTrusted() else {
            return failed(appKey, pid, .permissionDenied, start)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(config.messagingTimeout))

        var visited = 0
        var truncated = false
        var actionProbeFailures = 0

        let root = walk(
            app, path: [], depth: 0,
            parentID: nil, windowID: nil,
            appKey: appKey, start: start,
            visited: &visited, truncated: &truncated, actionProbeFailures: &actionProbeFailures
        )

        var nodes = root.map { [$0] } ?? []
        // The menu bar is NOT reachable via AXChildren — it hangs off the
        // app's AXMenuBar attribute. Walk it as a second root with "mb" ids
        // (windowless entities: window space falls back to screen space).
        if let menuBar = menuBarElement(app),
           let mbRoot = walk(
               menuBar, path: [], depth: 0,
               parentID: nil, windowID: nil,
               appKey: appKey, idPrefix: "mb", start: start,
               visited: &visited, truncated: &truncated, actionProbeFailures: &actionProbeFailures
           ) {
            nodes.append(mbRoot)
        }

        var snapshot = AXAppSnapshot(
            appKey: appKey, pid: pid, nodes: nodes,
            visited: visited, actionProbeFailures: actionProbeFailures, truncated: truncated,
            error: nil, elapsed: Date().timeIntervalSince(start),
            cgDiagnosticsEnabled: config.cgProbeEnabled
        )
        // Always collected (V3): one cheap CGWindowList call per capture,
        // no IPC to the target app — feeds window z-order ranks.
        snapshot.cgWindows = cgProvider.onScreenWindows(pid: pid)
        if snapshot.nodes.isEmpty {
            snapshot.error = .noWindows
        }
        return snapshot
    }

    private func menuBarElement(_ app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private func failed(_ appKey: String, _ pid: Int32, _ error: AXSnapshotError, _ start: Date) -> AXAppSnapshot {
        AXAppSnapshot(
            appKey: appKey, pid: pid, nodes: [],
            visited: 0, truncated: false,
            error: error, elapsed: Date().timeIntervalSince(start)
        )
    }

    /// Subtree capture rooted at the window at `path` (indices under the app
    /// root). Node ids are generated from `path`, so incremental captures
    /// produce ids identical to the full capture — enabling per-window merges.
    /// Returns nil if the window cannot be resolved.
    public func snapshotWindow(pid: Int32, appKey: String, path: [Int]) -> AXAppSnapshot? {
        let start = Date()
        guard AXIsProcessTrusted(), !path.isEmpty else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(config.messagingTimeout))
        guard let element = resolveElement(app, path: path) else { return nil }

        var visited = 0
        var truncated = false
        var actionProbeFailures = 0
        let root = walk(
            element, path: path, depth: 0,
            parentID: nil, windowID: nil,
            appKey: appKey, start: start,
            visited: &visited, truncated: &truncated, actionProbeFailures: &actionProbeFailures
        )
        guard let root else { return nil }
        return AXAppSnapshot(
            appKey: appKey, pid: pid, nodes: [root],
            visited: visited, actionProbeFailures: actionProbeFailures, truncated: truncated,
            error: nil, elapsed: Date().timeIntervalSince(start)
        )
    }

    private func resolveElement(_ element: AXUIElement, path: [Int]) -> AXUIElement? {
        var current = element
        for index in path {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &ref) == .success,
                  let ref, CFGetTypeID(ref) == CFArrayGetTypeID() else { return nil }
            let children = ref as! [AnyObject]
            guard index < children.count else { return nil }
            current = children[index] as! AXUIElement
        }
        return current
    }

    private func walk(
        _ element: AXUIElement,
        path: [Int],
        depth: Int,
        parentID: String?,
        windowID: String?,
        appKey: String,
        idPrefix: String? = nil,
        start: Date,
        visited: inout Int,
        truncated: inout Bool,
        actionProbeFailures: inout Int
    ) -> AXNode? {
        guard visited < config.nodeBudget else {
            truncated = true
            return nil
        }
        guard Date().timeIntervalSince(start) < config.maxCaptureTime else {
            truncated = true
            return nil
        }
        visited += 1

        let attrs = readAttributes(element)
        if !attrs.actionProbeOK { actionProbeFailures += 1 }

        let role = attrs.role
        let id = makeID(appKey: appKey, path: path, prefix: idPrefix)
        let ownWindowID = (role == kAXWindowRole) ? id : windowID

        var node = AXNode(
            id: id,
            role: role,
            title: attrs.title,
            detail: attrs.detail,
            identifier: attrs.identifier,
            value: attrs.value,
            subrole: attrs.subrole,
            focused: attrs.focused ?? false,
            selected: attrs.selected ?? false,
            placeholder: attrs.placeholder,
            enabled: attrs.enabled ?? true,
            actions: attrs.actions,
            frame: frame(from: attrs.position, size: attrs.size),
            parentID: parentID,
            windowID: ownWindowID
        )

        guard depth < config.depthLimit else { return node }

        for (i, child) in attrs.children.enumerated() {
            guard visited < config.nodeBudget else {
                truncated = true
                node.truncated = true
                break
            }
            if let childNode = walk(
                child, path: path + [i], depth: depth + 1,
                parentID: id, windowID: ownWindowID,
                appKey: appKey, idPrefix: idPrefix, start: start,
                visited: &visited, truncated: &truncated, actionProbeFailures: &actionProbeFailures
            ) {
                node.children.append(childNode)
            }
        }
        return node
    }

    /// ID grammar: "<appKey>:<indices>" for the app tree ("root" for the app
    /// element itself); "<appKey>:mb[-indices]" for the menu-bar subtree.
    /// The "mb" prefix deliberately fails numeric path parsing, so per-window
    /// subtree capture never tries to resolve menu-bar nodes (they have no
    /// window); those events fall back to full capture.
    private func makeID(appKey: String, path: [Int], prefix: String? = nil) -> String {
        let joined = path.map(String.init).joined(separator: "-")
        if let prefix {
            return path.isEmpty ? "\(appKey):\(prefix)" : "\(appKey):\(prefix)-\(joined)"
        }
        return path.isEmpty ? "\(appKey):root" : "\(appKey):\(joined)"
    }

    // MARK: - Attribute reading

    private struct AttrBatch {
        var role: String?
        var title: String?
        var detail: String?
        var identifier: String?
        var value: String?
        var subrole: String?
        var focused: Bool?
        var selected: Bool?
        var placeholder: String?
        var enabled: Bool?
        var position: CGPoint?
        var size: CGSize?
        var children: [AXUIElement] = []
        var actions: [String] = []
        /// False when the AX action call errored (as opposed to legitimately
        /// reporting no actions). Carried out so the failure is countable.
        var actionProbeOK = true
    }

    private func readAttributes(_ element: AXUIElement) -> AttrBatch {
        var batch = AttrBatch()
        var names: [String] = [
            kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
            kAXIdentifierAttribute, kAXEnabledAttribute, kAXPositionAttribute,
            kAXSizeAttribute, kAXChildrenAttribute,
            // V3: semantic state the AI desktop reasons over. Value/state are
            // read in the same batch (per-node single reads would blow the
            // capture wall-clock budget on dense pages).
            kAXValueAttribute, kAXSubroleAttribute, kAXFocusedAttribute,
            kAXSelectedAttribute, kAXPlaceholderValueAttribute,
        ]
        // NOTE: "AXActions" is deliberately NOT in this batch. Asking for it
        // via AXUIElementCopyAttributeValue fails with
        // kAXErrorUnsupportedAttribute (-25205) on real elements, and when it
        // does return, it is an array of {name, selector} dictionaries — never
        // a [String], so the old `value as? [String]` could never succeed.
        // Net effect was actions==[] for every entity in the frame. Actions
        // come from AXUIElementCopyActionNames below.

        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            element, names as CFArray, [], &values
        )
        guard err == .success, let values else {
            // Fall back to reading role + children individually for robust traversal.
            batch.role = stringAttribute(element, kAXRoleAttribute)
            if let children = childrenAttribute(element) {
                batch.children = children
            }
            return batch
        }

        let raw = values as [AnyObject]
        for (i, name) in names.enumerated() {
            guard i < raw.count else { break }
            let value = raw[i]
            if value is NSNull { continue }
            switch name {
            case kAXRoleAttribute:
                batch.role = value as? String
            case kAXTitleAttribute:
                batch.title = value as? String
            case kAXDescriptionAttribute:
                batch.detail = value as? String
            case kAXIdentifierAttribute:
                batch.identifier = value as? String
            case kAXEnabledAttribute:
                batch.enabled = (value as? NSNumber)?.boolValue
            case kAXPositionAttribute:
                batch.position = cgPoint(from: value)
            case kAXSizeAttribute:
                batch.size = cgSize(from: value)
            case kAXChildrenAttribute:
                batch.children = elements(from: value)
            case kAXValueAttribute:
                batch.value = Self.valueString(from: value)
            case kAXSubroleAttribute:
                batch.subrole = value as? String
            case kAXFocusedAttribute:
                batch.focused = (value as? NSNumber)?.boolValue
            case kAXSelectedAttribute:
                batch.selected = (value as? NSNumber)?.boolValue
            case kAXPlaceholderValueAttribute:
                batch.placeholder = value as? String
            default:
                break
            }
        }
        if config.includeActions, let role = batch.role, Self.rolesWithActions.contains(role) {
            let probe = Self.actionProbe(of: element)
            batch.actions = probe.names
            batch.actionProbeOK = probe.ok
        } else {
            batch.actionProbeOK = true   // not probed, so not a failure
        }
        return batch
    }

    /// Enumerable actions for an element, via the dedicated Action API.
    ///
    /// The Action API is the only correct source: the `AXActions` attribute
    /// path is unsupported (-25205) on the elements that matter and returns a
    /// shape (`[[String: String]]`) that the old `[String]` cast could never
    /// match, which is why every entity in every frame reported zero actions —
    /// silently starving both the topology score and the semantic action bridge.
    ///
    /// Cost: one AX round-trip per element, so it is gated on `includeActions`
    /// and restricted to roles that can meaningfully carry actions.
    static func actionNames(of element: AXUIElement) -> [String] {
        var cfNames: CFArray?
        guard AXUIElementCopyActionNames(element, &cfNames) == .success else { return [] }
        return cfNames as? [String] ?? []
    }

    /// Same read, but reports whether the AX call actually succeeded.
    ///
    /// Distinguishing "AX says this element has no actions" from "the AX call
    /// failed" matters: both used to collapse into an empty array, which is
    /// precisely how a systematically broken field stays invisible.
    static func actionProbe(of element: AXUIElement) -> (names: [String], ok: Bool) {
        var cfNames: CFArray?
        let err = AXUIElementCopyActionNames(element, &cfNames)
        guard err == .success else { return ([], false) }
        return (cfNames as? [String] ?? [], true)
    }

    /// Roles whose elements can carry actions. Text, images, cells and
    /// containers never do, and asking every node in a dense tree (a web page
    /// is thousands of static-text nodes) would add thousands of AX
    /// round-trips per sweep for guaranteed-empty results.
    static let rolesWithActions: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXComboBox", "AXTextField", "AXTextArea",
        "AXSecureTextField", "AXSlider", "AXIncrementor", "AXStepper",
        "AXLink", "AXDisclosureTriangle", "AXTabButton", "AXSegmentedControl",
        "AXToolbarButton", "AXSwitch", "AXRatingIndicator",
    ]

    /// AXValue arrives in many shapes (String / NSNumber / CFBoolean /
    /// NSAttributedString / AXValue). Coerce to a short display string and
    /// cap it: terminal scrollbacks and document text areas can otherwise
    /// pump megabytes into every frame.
    static func valueString(from value: AnyObject, cap: Int = 512) -> String? {
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

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func childrenAttribute(_ element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else { return nil }
        return elements(from: ref!)
    }

    private func frame(from position: CGPoint?, size: CGSize?) -> CGRect? {
        guard let position, let size, size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func cgPoint(from value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(ax) == .cgPoint else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(ax, .cgPoint, &p) else { return nil }
        return p
    }

    private func cgSize(from value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(ax) == .cgSize else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(ax, .cgSize, &s) else { return nil }
        return s
    }

    private func elements(from value: AnyObject) -> [AXUIElement] {
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! [AnyObject]
        return array.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }
}
