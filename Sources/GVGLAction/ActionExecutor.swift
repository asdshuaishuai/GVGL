import ApplicationServices
import Foundation
import GVGLCore
import GVGLQuery

public struct ActionFailure: Error, CustomStringConvertible {
    public var error: ActionError
    public init(_ code: ActionErrorCode, _ message: String) {
        self.error = ActionError(code, message)
    }
    public var description: String { "\(error.code.rawValue): \(error.message)" }
}

/// How to get text into a field.
public enum TypeMethod: String, Sendable {
    /// Pick per element capability: AXValue write → paste (long/non-ASCII) →
    /// Unicode key events.
    case auto
    /// `AXUIElementSetAttributeValue(kAXValueAttribute)` — exact, atomic, and
    /// rejected by many web/Electron fields.
    case setValue = "setvalue"
    /// Device-level Unicode key events — layout/IME independent, needs focus.
    case keys
    /// Clipboard + `Cmd+V`, clipboard restored — best for long or CJK text.
    case paste
}

public struct ExecutorOptions: Sendable {
    public var socketPath: String
    /// Resolve and hit-test, then stop before any event is posted.
    public var dryRun = false
    /// Wait for an observable reaction and report it.
    public var verify = true
    public var timeout: TimeInterval = 2.0
    public var pollInterval: TimeInterval = 0.08
    /// Restrict actions to these app keys ("pid:NNN"), pids, or app names.
    public var allowAppKeys: Set<String>?
    /// Typing into AXSecureTextField is refused unless explicitly allowed.
    public var allowSecureFields = false
    /// Post a click even when the app cannot answer a hit-test. Off by default:
    /// a blind click is exactly what this layer exists to avoid.
    public var allowBlindClick = false
    /// Act on a low-confidence / near-tied query result.
    public var allowAmbiguous = false

    public init(socketPath: String) {
        self.socketPath = socketPath
    }
}

public enum TargetSpec {
    case id(String)
    case query(QueryParams)
}

/// A validated, live target: the entity from the frame plus the AX element it
/// resolved to, read *now*.
public struct ResolvedTarget {
    public var entity: Entity
    public var element: AXUIElement
    public var appElement: AXUIElement
    public var state: AXElementState
    public var pid: Int32
    public var screen: ScreenInfo
    /// Non-fatal notes (re-validation, low confidence, fallback choice).
    public var warnings: [String]
}

/// Perception → action → verification.
///
/// Design boundaries worth stating because they are load-bearing:
///  - The daemon is never asked to act. It stays read-only and auditable; this
///    executor is a client that reads frames and talks to AX/CGEvent itself.
///  - Element ids are addresses, not handles. Every action re-validates the
///    resolved element against the entity (role/identifier/position) and
///    re-locates once before failing, because the frame is always slightly
///    older than the desktop.
///  - Clicks are hit-tested with `AXUIElementCopyElementAtPosition` and refused
///    when something else is on top. No screenshot is involved anywhere.
public final class ActionExecutor {
    public let options: ExecutorOptions
    let source: FrameSource

    public init(options: ExecutorOptions, source: FrameSource? = nil) {
        self.options = options
        self.source = source ?? SocketFrameSource(socketPath: options.socketPath)
    }

    // MARK: - Find

    public func find(_ params: QueryParams) throws -> (results: [ScoredEntity], frame: GVGLFrame) {
        let frame = try source.frame(app: params.app)
        return (QueryEngine.query(frame: frame, params: params).ranked, frame)
    }

    public func queryResult(_ params: QueryParams) throws -> QueryResult {
        let frame = try source.frame(app: params.app)
        return QueryEngine.query(frame: frame, params: params)
    }

    // MARK: - Resolution

    public func resolve(_ spec: TargetSpec) throws -> ResolvedTarget {
        try ensureTrusted()
        let (entity, frame) = try locate(spec)
        try enforcePolicy(entity: entity)

        var warnings: [String] = []

        // Attempt 1: the id as given, validated against a live AX read.
        if var target = tryAttempt(entity: entity, frame: frame),
           target.state.matches(entity, screen: frame.screen) {
            target.warnings = warnings
            return target
        }

        // Attempt 2/3: the model (or the tree) moved between capture and now.
        if let refreshed = try? source.frame(app: entity.appID) {
            if let same = refreshed.allEntities.first(where: { $0.id == entity.id }),
               var target = tryAttempt(entity: same, frame: refreshed),
               target.state.matches(same, screen: refreshed.screen) {
                warnings.append("element re-validated after a model refresh")
                target.warnings = warnings
                return target
            }
            if let moved = relocate(entity: entity, in: refreshed),
               var target = tryAttempt(entity: moved, frame: refreshed),
               target.state.matches(moved, screen: refreshed.screen) {
                warnings.append("element id changed (\(entity.id) → \(moved.id)); re-located by role/identity")
                target.warnings = warnings
                return target
            }
        }

        throw ActionFailure(
            .staleReference,
            "element \(entity.id) (\(entity.role) \(entity.title ?? entity.value ?? "")) no longer matches the accessibility tree; re-run `find`"
        )
    }

    private func locate(_ spec: TargetSpec) throws -> (Entity, GVGLFrame) {
        switch spec {
        case .id(let id):
            guard let path = ElementPath.parse(id), let pid = path.pid else {
                throw ActionFailure(.invalidArgument, "not an element id: \(id)")
            }
            let appKey = "pid:\(pid)"
            let frame = try source.frame(app: appKey)
            guard let entity = frame.allEntities.first(where: { $0.id == id }) else {
                throw ActionFailure(.notFound, "no entity \(id) in the current frame of \(appKey)")
            }
            return (entity, frame)

        case .query(let params):
            let frame = try source.frame(app: params.app)
            let result = QueryEngine.query(frame: frame, params: params)
            guard let best = result.best else {
                throw ActionFailure(.notFound, "no element matches the query")
            }
            switch result.status {
            case .notFound:
                throw ActionFailure(
                    .notFound,
                    "no confident match (best \(String(format: "%.2f", best.score)) \(best.entity.role) \(best.entity.title ?? best.entity.value ?? "")); use `find` to inspect candidates"
                )
            case .ambiguous, .axWeak:
                // A clear winner is actionable even at lower confidence; a tie
                // is not. Acting on a coin flip is how the wrong thing gets
                // clicked.
                let margin = result.ranked.count > 1 ? best.score - result.ranked[1].score : 1.0
                if margin < 0.05, !options.allowAmbiguous {
                    throw ActionFailure(
                        .ambiguousMatch,
                        "ambiguous match (margin \(String(format: "%.2f", margin))); narrow the query or pass --allow-ambiguous"
                    )
                }
            case .hit:
                break
            }
            return (best.entity, frame)
        }
    }

    private func tryAttempt(entity: Entity, frame: GVGLFrame) -> ResolvedTarget? {
        let resolver = AXResolver(pid: entity.pid)
        let app = resolver.application()
        guard let element = try? resolver.resolve(entity.id) else { return nil }
        let state = AXElementState.read(element)
        return ResolvedTarget(
            entity: entity, element: element, appElement: app,
            state: state, pid: entity.pid, screen: frame.screen, warnings: []
        )
    }

    /// Finds the same element after its path shifted: same app, same role, same
    /// identifier (or title), preferably the same window, and only when the
    /// answer is unique.
    private func relocate(entity: Entity, in frame: GVGLFrame) -> Entity? {
        var pool = frame.allEntities.filter {
            $0.role == entity.role && $0.appID == entity.appID && $0.id != entity.id
        }
        guard !pool.isEmpty else { return nil }

        if let identifier = entity.identifier, !identifier.isEmpty {
            pool = pool.filter { $0.identifier == identifier }
        } else if let title = entity.title, !title.isEmpty {
            pool = pool.filter { $0.title == title }
        } else {
            guard let closest = pool.min(by: { normalizedDistance($0, entity) < normalizedDistance($1, entity) }),
                  normalizedDistance(closest, entity) < 0.02 else { return nil }
            return closest
        }

        if let window = entity.windowID {
            let sameWindow = pool.filter { $0.windowID == window }
            if sameWindow.count == 1 { return sameWindow[0] }
        }
        return pool.count == 1 ? pool[0] : nil
    }

    private func normalizedDistance(_ a: Entity, _ b: Entity) -> Double {
        let dx = a.geometry.centerX - b.geometry.centerX
        let dy = a.geometry.centerY - b.geometry.centerY
        return (dx * dx + dy * dy).squareRoot()
    }

    private func enforcePolicy(entity: Entity) throws {
        guard let allowed = options.allowAppKeys else { return }
        let matches = allowed.contains(entity.appID)
            || allowed.contains(String(entity.pid))
            || entity.appName.map { allowed.contains($0) } == true
        guard matches else {
            throw ActionFailure(
                .blockedByPolicy,
                "app \(entity.appID) (\(entity.appName ?? "?")) is not in the allow list"
            )
        }
    }

    // MARK: - Snapshots & verification

    public func currentVersion() -> UInt64? {
        try? source.version()
    }

    func beforeSnapshot(_ target: ResolvedTarget, version: UInt64?) -> ActionSnapshot {
        ActionSnapshot(
            version: version,
            element: ElementSnapshot(state: target.state, id: target.entity.id),
            focusedID: target.state.focused ? target.entity.id : nil,
            changedApps: []
        )
    }

    /// Reads the target's state after an action. A path that no longer resolves
    /// means the element is gone (dialog closed, row removed) — reported as
    /// `exists: false` rather than an error, because that is often success.
    func afterSnapshot(_ target: ResolvedTarget, version: UInt64?) -> ActionSnapshot {
        var element = ElementSnapshot.missing
        if let fresh = try? AXResolver(pid: target.pid).resolve(target.entity.id) {
            let state = AXElementState.read(fresh)
            if state.matches(target.entity, screen: target.screen) {
                element = ElementSnapshot(state: state, id: target.entity.id)
            }
        }
        var focusedID: String?
        if let frame = try? source.frame(app: "pid:\(target.pid)") {
            focusedID = frame.allEntities.first(where: { $0.focused })?.id
        }
        return ActionSnapshot(version: version, element: element, focusedID: focusedID, changedApps: [])
    }

    enum Expectation {
        case anyChange
        case focused
        case valueEquals(String)
        case valueContains(String)
        case exists(Bool)
    }

    /// Waits for a reaction, then decides whether it matched the expectation.
    /// `changed` and `verified` answer different questions on purpose: the
    /// desktop may change for unrelated reasons, and an action may succeed
    /// without a visible effect.
    func verify(target: ResolvedTarget, beforeVersion: UInt64?, before: ActionSnapshot,
                expectation: Expectation, timeout: TimeInterval)
        -> (changed: Bool, verified: Bool, after: ActionSnapshot) {
        guard options.verify, let beforeVersion else {
            let after = afterSnapshot(target, version: try? source.version())
            return (false, false, after)
        }
        let observed = ChangeWaiter.wait(
            source: source, since: beforeVersion, timeout: timeout, poll: options.pollInterval
        )
        let after = afterSnapshot(target, version: try? source.version())
        let elementChanged = after.element?.value != before.element?.value
            || after.element?.focused != before.element?.focused
            || after.element?.exists != before.element?.exists
        let changed = observed != nil || elementChanged

        let verified: Bool
        switch expectation {
        case .anyChange:
            verified = changed
        case .focused:
            verified = after.element?.focused == true
        case .valueEquals(let text):
            verified = after.element?.value == text
        case .valueContains(let text):
            guard let value = after.element?.value else {
                verified = false
                break
            }
            verified = value.contains(text)
        case .exists(let expected):
            verified = (after.element?.exists ?? false) == expected
        }
        return (changed, verified, after)
    }

    // MARK: - Focus

    @discardableResult
    func focusElement(_ target: ResolvedTarget) -> AXElementState {
        guard target.state.focusedSettable, !target.state.focused else { return target.state }
        _ = AXUIElementSetAttributeValue(
            target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        Thread.sleep(forTimeInterval: 0.03)
        return AXElementState.read(target.element)
    }

    public func focus(_ spec: TargetSpec) throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "focus")
        let target = try resolve(spec)
        result.target = ActionTargetSummary(entity: target.entity, liveFrame: target.state.frame)
        result.warnings = target.warnings
        let version = currentVersion()
        result.before = beforeSnapshot(target, version: version)

        if options.dryRun {
            result.dryRun = true
            result.method = "ax_focused"
            result.latencyMS = elapsed(started)
            return result
        }
        guard target.state.focusedSettable else {
            throw ActionFailure(.actionUnsupported, "element does not allow AXFocused to be set")
        }
        _ = AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        result.method = "ax_focused"
        let verification = verify(target: target, beforeVersion: version, before: result.before!,
                                  expectation: .focused, timeout: options.timeout)
        result.changed = verification.changed
        result.verified = verification.verified
        result.after = verification.after
        result.latencyMS = elapsed(started)
        return result
    }

    // MARK: - setValue

    public func setValue(_ spec: TargetSpec, text: String) throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "set")
        let target = try resolve(spec)
        result.target = ActionTargetSummary(entity: target.entity, liveFrame: target.state.frame)
        result.warnings = target.warnings
        let version = currentVersion()
        result.before = beforeSnapshot(target, version: version)

        guard target.state.valueSettable else {
            throw ActionFailure(.actionUnsupported, "element does not allow AXValue to be set (try `type`)")
        }
        if options.dryRun {
            result.dryRun = true
            result.method = "ax_set_value"
            result.latencyMS = elapsed(started)
            return result
        }
        let error = AXUIElementSetAttributeValue(
            target.element, kAXValueAttribute as CFString, text as CFString
        )
        guard error == .success else {
            throw ActionFailure(.actionUnsupported, "AXValue write failed (AXError \(error.rawValue))")
        }
        result.method = "ax_set_value"
        let verification = verify(target: target, beforeVersion: version, before: result.before!,
                                  expectation: .valueEquals(text), timeout: options.timeout)
        result.changed = verification.changed
        result.verified = verification.verified
        result.after = verification.after
        result.latencyMS = elapsed(started)
        return result
    }

    // MARK: - Read text

    /// Reads a window (or the whole desktop) as text, in document order.
    ///
    /// This is the screenshot-free answer to "what does this window say?".
    /// The AX tree already contains the visible strings; concatenating them in
    /// natural AX order with role labels is what an OCR pass would have been
    /// used for, minus the image.
    public func transcript(appKey: String? = nil, windowID: String? = nil,
                           maxChars: Int = 20000) throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "transcript")
        let frame = try source.frame(app: appKey)
        let entities = frame.allEntities

        let scoped: [Entity]
        if let windowID {
            // Include the window itself (title header) and everything under it.
            scoped = entities.filter {
                $0.id == windowID || $0.windowID == windowID
            }
            if scoped.isEmpty {
                throw ActionFailure(.notFound, "no entities under window \(windowID)")
            }
            result.target = scoped.first(where: { $0.id == windowID }).map {
                ActionTargetSummary(entity: $0)
            }
        } else {
            scoped = entities
        }

        var lines: [JSONValue] = []
        var plain: [String] = []
        var characters = 0
        var truncated = false
        var lastText = ""

        for entity in scoped {
            guard let text = Self.transcriptText(for: entity), text != lastText else { continue }
            lastText = text
            if characters + text.count > maxChars {
                truncated = true
                break
            }
            characters += text.count
            plain.append(Self.transcriptLine(for: entity, text: text))
            lines.append(.object([
                "id": .string(entity.id),
                "role": .string(entity.role),
                "text": .string(text),
                "focused": .bool(entity.focused),
                "pixel": .numbers([
                    entity.geometry.centerX * frame.screen.width,
                    entity.geometry.centerY * frame.screen.height,
                ]),
            ]))
        }

        result.method = "ax_scene"
        result.data = .object([
            "text": .string(plain.joined(separator: "\n")),
            "lines": .array(lines),
            "characters": .number(Double(characters)),
            "entities": .number(Double(scoped.count)),
            "truncated": .bool(truncated),
        ])
        if truncated {
            result.warnings.append("transcript truncated at \(maxChars) characters")
        }
        if scoped.isEmpty {
            result.warnings.append("frame has no entities (app not captured yet?)")
        }
        result.latencyMS = elapsed(started)
        return result
    }

    /// The text a sighted user would read from this element. Containers and
    /// pure layout roles contribute nothing; controls contribute their label.
    ///
    /// Label sources, in order: title → placeholder → detail. `detail` matters
    /// because SwiftUI (and much of Electron) exposes a control's visible label
    /// as AXDescription, which the snapshotter stores there.
    ///
    /// `value` is content, not a label — but it is information a reader needs,
    /// so a text field's content and a checkbox's state are appended when they
    /// differ from the label. Using value as a *fallback label* (the previous
    /// order) turned "允许执行动作" into a bare "0".
    static func transcriptText(for entity: Entity) -> String? {
        func clean(_ text: String?) -> String? {
            guard let text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let label = clean(entity.title) ?? clean(entity.placeholder) ?? clean(entity.detail)
        let content = clean(entity.value)
        switch (label, content) {
        case let (label?, content?) where label != content:
            return "\(label): \(content)"
        case let (label?, _):
            return label
        case let (nil, content?):
            return content
        default:
            return nil
        }
    }

    static func transcriptLine(for entity: Entity, text: String) -> String {
        switch entity.role {
        case "AXWindow", "AXSheet", "AXDrawer":
            return "## \(text)"
        case "AXButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTab", "AXCell":
            return "[\(entity.role.replacingOccurrences(of: "AX", with: "").lowercased())] \(text)"
        default:
            return text
        }
    }

    public func readText(_ spec: TargetSpec, cap: Int = 8000) throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "text")
        let target = try resolve(spec)
        result.target = ActionTargetSummary(entity: target.entity, liveFrame: target.state.frame)
        result.warnings = target.warnings
        let text = AXElementState.fullValue(target.element, cap: cap)
        result.data = text.map(JSONValue.string) ?? .null
        result.method = "ax_value"
        result.ok = text != nil
        if text == nil {
            result.warnings.append("element exposes no readable AXValue")
        }
        result.latencyMS = elapsed(started)
        return result
    }

    // MARK: - Press (semantic first, hit-tested click as fallback)

    public func press(_ spec: TargetSpec, axAction: String? = nil) throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "press")
        let target = try resolve(spec)
        result.target = ActionTargetSummary(entity: target.entity, liveFrame: target.state.frame)
        result.warnings = target.warnings

        let preferred = axAction.map { [$0] }
            ?? ["AXPress", "AXConfirm", "AXPick", "AXOpen", "AXShowMenu"]
        guard let action = preferred.first(where: { target.state.actions.contains($0) }) else {
            result.warnings.append(
                "no AX action exposed (\(target.state.actions.isEmpty ? "none" : target.state.actions.joined(separator: ","))); using a hit-tested click"
            )
            return try click(target, button: .left, count: 1,
                             method: "cg_click_fallback", into: result, started: started)
        }

        let version = currentVersion()
        result.before = beforeSnapshot(target, version: version)
        let methodName = Self.methodName(forAction: action)
        if options.dryRun {
            result.dryRun = true
            result.method = methodName
            result.warnings.append("dry run: would perform \(action)")
            result.latencyMS = elapsed(started)
            return result
        }

        let error = AXUIElementPerformAction(target.element, action as CFString)
        result.attempts.append(ActionAttempt(
            methodName, ok: error == .success,
            detail: error == .success ? nil : "AXError \(error.rawValue)"
        ))
        guard error == .success else {
            throw ActionFailure(.actionUnsupported, "AX \(action) failed (AXError \(error.rawValue))")
        }

        result.method = methodName
        let verification = verify(target: target, beforeVersion: version, before: result.before!,
                                  expectation: .anyChange, timeout: options.timeout)
        result.changed = verification.changed
        result.verified = verification.verified
        result.after = verification.after
        result.latencyMS = elapsed(started)
        return result
    }

    // MARK: - Click (pointer)

    public func click(_ spec: TargetSpec, button: InputSynthesizer.MouseButton = .left,
                      count: Int = 1) throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "click")
        let target = try resolve(spec)
        result.target = ActionTargetSummary(entity: target.entity, liveFrame: target.state.frame)
        result.warnings = target.warnings
        return try click(target, button: button, count: count,
                         method: methodName(button: button, count: count),
                         into: result, started: started)
    }

    func click(_ target: ResolvedTarget, button: InputSynthesizer.MouseButton, count: Int,
               method: String, into result: ActionResult, started: DispatchTime) throws -> ActionResult {
        var result = result
        guard let frame = target.state.frame else {
            throw ActionFailure(.invalidArgument, "element has no frame to click")
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        try guardClickPoint(target: target, point: point, into: &result)

        let version = currentVersion()
        result.before = beforeSnapshot(target, version: version)
        result.method = method
        if options.dryRun {
            result.dryRun = true
            result.warnings.append("dry run: would click at (\(Int(point.x)), \(Int(point.y)))")
            result.latencyMS = elapsed(started)
            return result
        }

        InputSynthesizer.click(at: point, button: button, count: count)
        result.attempts.append(ActionAttempt(method, ok: true, detail: "click at \(Int(point.x)),\(Int(point.y))"))
        let verification = verify(target: target, beforeVersion: version, before: result.before!,
                                  expectation: .anyChange, timeout: options.timeout)
        result.changed = verification.changed
        result.verified = verification.verified
        result.after = verification.after
        result.latencyMS = elapsed(started)
        return result
    }

    /// Refuses to click unless the element under the point is the target (or a
    /// child/container of it).
    func guardClickPoint(target: ResolvedTarget, point: CGPoint,
                         into result: inout ActionResult) throws {
        switch ClickGuard.check(target: target.element, app: target.appElement, at: point) {
        case .clear:
            return
        case .obscured(let role, let title):
            throw ActionFailure(
                .targetObscured,
                "another element covers the click point (\(role ?? "unknown") \(title ?? "")); refusing to click"
            )
        case .unavailable:
            if options.allowBlindClick {
                result.warnings.append("hit-test unavailable; --allow-blind-click permitted a blind click")
                return
            }
            throw ActionFailure(
                .targetObscured,
                "the app cannot answer a hit-test at this point; refusing a blind click (override with --allow-blind-click)"
            )
        }
    }

    private func methodName(button: InputSynthesizer.MouseButton, count: Int) -> String {
        switch (button, count) {
        case (.left, 1): return "cg_click"
        case (.left, 2): return "cg_double_click"
        case (.right, _): return "cg_right_click"
        case (.middle, _): return "cg_middle_click"
        default: return "cg_click_\(button.rawValue)_\(count)"
        }
    }

    /// "AXPress" → "ax_press" (not "ax_axpress"): the result vocabulary is part
    /// of the CLI contract, so it should read the way an agent expects.
    static func methodName(forAction action: String) -> String {
        let stripped = action.hasPrefix("AX") ? String(action.dropFirst(2)) : action
        return "ax_" + stripped.lowercased()
    }

    // MARK: - Type

    public func type(_ spec: TargetSpec, text: String,
                     method: TypeMethod = .auto, submit: Bool = false) throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "type")
        let target = try resolve(spec)
        result.target = ActionTargetSummary(entity: target.entity, liveFrame: target.state.frame)
        result.warnings = target.warnings

        if target.state.isSecureTextField, !options.allowSecureFields {
            throw ActionFailure(
                .blockedByPolicy,
                "refusing to type into a secure field (override with --allow-secure-field)"
            )
        }
        let version = currentVersion()
        result.before = beforeSnapshot(target, version: version)

        if options.dryRun {
            result.dryRun = true
            result.method = "type_\(method.rawValue)"
            result.latencyMS = elapsed(started)
            return result
        }

        // Focus is a precondition, not a nicety: Unicode key events and Cmd+V
        // go wherever focus is, and typing into an unknown control is worse
        // than failing.
        let focusedState = focusElement(target)
        guard focusedState.focused else {
            throw ActionFailure(
                .focusFailed,
                "could not move keyboard focus to \(target.entity.id); refusing to type into an unknown control"
            )
        }

        let resolvedMethod = method == .auto ? automaticMethod(text: text, state: focusedState) : method
        result.method = resolvedMethod == .setValue ? "ax_set_value" : "cg_\(resolvedMethod.rawValue)"

        switch resolvedMethod {
        case .setValue:
            guard focusedState.valueSettable else {
                throw ActionFailure(.actionUnsupported, "element does not allow AXValue to be set")
            }
            let error = AXUIElementSetAttributeValue(
                target.element, kAXValueAttribute as CFString, text as CFString
            )
            result.attempts.append(ActionAttempt("ax_set_value", ok: error == .success,
                                                 detail: "AXError \(error.rawValue)"))
            guard error == .success else {
                throw ActionFailure(.actionUnsupported, "AXValue write failed (AXError \(error.rawValue))")
            }
        case .keys:
            InputSynthesizer.type(text)
            result.attempts.append(ActionAttempt("cg_unicode_keys", ok: true,
                                                 detail: "\(text.utf16.count) UTF-16 units"))
        case .paste:
            ClipboardService.substituting(text) {
                if let chord = KeyChord.parse("cmd+v") {
                    InputSynthesizer.press(chord)
                }
                // The target app must actually consume the pasteboard before
                // it is restored; 350ms is comfortably above observed latency.
                Thread.sleep(forTimeInterval: 0.35)
            }
            result.attempts.append(ActionAttempt("cg_paste", ok: true, detail: "\(text.count) characters"))
        case .auto:
            break // resolved above
        }

        if submit, let chord = KeyChord.parse("return") {
            InputSynthesizer.press(chord)
            result.attempts.append(ActionAttempt("cg_return", ok: true))
        }

        // A secure field never reveals its value, so "did it work" cannot be
        // answered by reading; say so instead of claiming success.
        let expectation: Expectation = target.state.isSecureTextField
            ? .anyChange
            : (resolvedMethod == .setValue ? .valueEquals(text) : .valueContains(text))
        let verification = verify(target: target, beforeVersion: version, before: result.before!,
                                  expectation: expectation, timeout: options.timeout)
        result.changed = verification.changed
        result.verified = verification.verified
        result.after = verification.after
        if !verification.verified, !target.state.isSecureTextField {
            result.warnings.append("typed text was not confirmed by reading the element value back")
        }
        result.latencyMS = elapsed(started)
        return result
    }

    private func automaticMethod(text: String, state: AXElementState) -> TypeMethod {
        if state.valueSettable { return .setValue }
        let isSimpleASCII = text.allSatisfy { $0.isASCII } && text.count <= 24
        return isSimpleASCII ? .keys : .paste
    }

    // MARK: - Keyboard

    public func sendKey(_ chordText: String, target spec: TargetSpec? = nil,
                        app appKey: String? = nil) throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "key")
        try ensureTrusted()
        guard let chord = KeyChord.parse(chordText) else {
            throw ActionFailure(.invalidArgument, "cannot parse key chord '\(chordText)'")
        }
        result.method = "cg_key"
        result.data = .object(["chord": .string(chord.display)])

        var resolved: ResolvedTarget?
        if let spec {
            let target = try resolve(spec)
            resolved = target
            result.target = ActionTargetSummary(entity: target.entity, liveFrame: target.state.frame)
            result.warnings = target.warnings
        }

        let version = currentVersion()
        result.before = ActionSnapshot(version: version)
        // Dry run stops before focus/activation: both are visible side effects.
        if options.dryRun {
            result.dryRun = true
            result.latencyMS = elapsed(started)
            return result
        }

        if let target = resolved {
            let focused = focusElement(target)
            guard focused.focused else {
                throw ActionFailure(.focusFailed, "could not focus \(target.entity.id) before sending the key")
            }
        }
        if let appKey {
            guard let pid = Self.parsePID(appKey) else {
                throw ActionFailure(.invalidArgument, "--app expects pid:NNN (got '\(appKey)')")
            }
            try activateAppPID(pid)
        }

        InputSynthesizer.press(chord)
        result.attempts.append(ActionAttempt("cg_key", ok: true, detail: chord.display))
        let observed = options.verify && version != nil
            ? ChangeWaiter.wait(source: source, since: version!, timeout: options.timeout, poll: options.pollInterval)
            : nil
        result.changed = observed != nil
        result.verified = observed != nil
        result.after = ActionSnapshot(version: try? source.version())
        result.latencyMS = elapsed(started)
        return result
    }

    // MARK: - Helpers

    func ensureTrusted() throws {
        guard AXIsProcessTrusted() else {
            throw ActionFailure(
                .permissionDenied,
                "Accessibility permission is not granted to this process; grant it to the agent/terminal that runs gvglact"
            )
        }
    }

    func elapsed(_ start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
