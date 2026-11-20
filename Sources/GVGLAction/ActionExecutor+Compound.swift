import AppKit
import ApplicationServices
import Foundation
import GVGLCore

/// Compound verbs: the ones that need more than one event or a running app.
extension ActionExecutor {

    // MARK: - Scroll

    /// Scrolls at the target's centre (macOS routes wheel events to the window
    /// under the pointer, so the pointer is placed first and hit-tested).
    ///
    /// `lines` follows CGEvent's convention: positive scrolls up. The CLI
    /// exposes `--up/--down` so nobody has to remember that.
    public func scroll(_ spec: TargetSpec, lines: Int32 = 3, to destination: String? = nil) throws -> ActionResult {
        if !mode.allowsSyntheticInput {
            return try scrollByAccessibility(spec, lines: lines, to: destination)
        }
        let started = DispatchTime.now()
        var result = ActionResult(action: "scroll")
        let target = try resolve(spec)
        result.target = ActionTargetSummary(entity: target.entity, liveFrame: target.state.frame)
        result.warnings = target.warnings

        guard let frame = target.state.frame else {
            throw ActionFailure(.invalidArgument, "element has no frame to scroll")
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        try guardClickPoint(target: target, point: point, into: &result)

        let version = currentVersion()
        result.before = beforeSnapshot(target, version: version)
        let normalized = destination?.lowercased()
        guard normalized == nil || normalized == "top" || normalized == "bottom" else {
            throw ActionFailure(.invalidArgument, "--to must be 'top' or 'bottom'")
        }

        if options.dryRun {
            result.dryRun = true
            result.method = normalized.map { "cg_scroll_to_\($0)" } ?? "cg_scroll"
            result.latencyMS = elapsed(started)
            return result
        }

        if let normalized {
            // Scroll until the desktop stops reacting, twice in a row. That is
            // a screenshot-free way to detect "reached the end" for content
            // whose scroll position is not exposed as an AX value.
            //
            // Two signals, because one is not enough: the model version (any
            // reaction) and, when the target is itself a scroll bar, its
            // AXValue (where we actually are). Version alone is lagging — the
            // daemon debounces and re-captures — so a 0.12s poll made this
            // stop one burst in and report success without reaching the top
            // (measured: final 0.084 instead of 0.0).
            let direction: Int32 = normalized == "top" ? 10 : -10
            var lastVersion = version
            var lastValue = scrollBarValue(target)
            var stagnantRounds = 0
            var rounds = 0
            while rounds < 40 {
                InputSynthesizer.scroll(at: point, vertical: direction)
                let deadline = Date().addingTimeInterval(0.6)
                var reacted = false
                while Date() < deadline {
                    let currentVersion = try? source.version()
                    let currentValue = scrollBarValue(target)
                    if currentVersion != lastVersion || currentValue != lastValue {
                        reacted = true
                        lastVersion = currentVersion
                        lastValue = currentValue
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if let value = lastValue {
                    if normalized == "top", value <= 0.001 { break }
                    if normalized == "bottom", value >= 0.999 { break }
                }
                if reacted {
                    stagnantRounds = 0
                } else {
                    stagnantRounds += 1
                }
                if stagnantRounds >= 2 { break }
                rounds += 1
            }
            result.method = "cg_scroll_to_\(normalized)"
            result.attempts.append(ActionAttempt(
                result.method!, ok: true,
                detail: "\(rounds + 1) wheel bursts, position \(lastValue.map { String(format: "%.3f", $0) } ?? "unknown")"
            ))
            result.data = .object([
                "to": .string(normalized),
                "position": lastValue.map(JSONValue.number) ?? .null,
                "rounds": .number(Double(rounds + 1)),
            ])
        } else {
            InputSynthesizer.scroll(at: point, vertical: lines)
            result.method = "cg_scroll"
            result.attempts.append(ActionAttempt("cg_scroll", ok: true, detail: "\(lines) lines"))
        }

        let verification = verify(target: target, beforeVersion: version, before: result.before!,
                                  expectation: .anyChange, timeout: options.timeout)
        result.changed = verification.changed
        result.verified = verification.verified
        result.after = verification.after
        result.latencyMS = elapsed(started)
        return result
    }

    /// Background-mode scrolling: write the scroll bar's AXValue. This is the
    /// same value a user drags, so content moves without a wheel event and
    /// without touching the pointer.
    private func scrollByAccessibility(_ spec: TargetSpec, lines: Int32,
                                       to destination: String?) throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "scroll")
        let target = try resolve(spec)
        result.target = ActionTargetSummary(entity: target.entity, liveFrame: target.state.frame)
        result.warnings = target.warnings

        let normalized = destination?.lowercased()
        guard normalized == nil || normalized == "top" || normalized == "bottom" else {
            throw ActionFailure(.invalidArgument, "--to must be 'top' or 'bottom'")
        }
        guard let scrollBar = scrollBarElement(for: target) else {
            throw ActionFailure(
                .blockedByPolicy,
                "no vertical AXScrollBar under \(target.entity.id) (\(target.entity.role)); "
                + "scrolling it needs synthetic wheel input (use --mode foreground)"
            )
        }

        let beforeValue = AXElementState.fullValue(scrollBar, cap: 64).flatMap(Double.init)
        let targetValue: Double
        if let normalized {
            targetValue = normalized == "top" ? 0 : 1
        } else {
            guard let beforeValue else {
                throw ActionFailure(
                    .actionUnsupported,
                    "scroll bar exposes no readable AXValue; cannot scroll it relatively in background mode "
                    + "(use --to top|bottom or --mode foreground)"
                )
            }
            targetValue = min(1, max(0, beforeValue - Double(lines) * 0.05))
        }

        let version = currentVersion()
        result.before = beforeSnapshot(target, version: version)
        result.method = "ax_scrollbar"
        result.data = .object([
            "to": normalized.map(JSONValue.string) ?? .null,
            "from": beforeValue.map(JSONValue.number) ?? .null,
            "requested": .number(targetValue),
            "scrollbar_role": .string("AXScrollBar"),
        ])
        result.warnings.append("background isolation: AXScrollBar value write; pointer not moved")

        if options.dryRun {
            result.dryRun = true
            result.latencyMS = elapsed(started)
            return result
        }

        let error = AXUIElementSetAttributeValue(
            scrollBar, kAXValueAttribute as CFString, NSNumber(value: targetValue)
        )
        guard error == .success else {
            throw ActionFailure(
                .actionUnsupported,
                "AXValue write on scroll bar failed (AXError \(error.rawValue))"
            )
        }
        result.attempts.append(ActionAttempt(
            "ax_scrollbar", ok: true,
            detail: "value \(String(format: "%.3f", targetValue))"
        ))

        // Read the position back; the app may clamp to its real range.
        var position = AXElementState.fullValue(scrollBar, cap: 64).flatMap(Double.init)
        for _ in 0..<10 {
            if let position, abs(position - targetValue) < 0.01 { break }
            Thread.sleep(forTimeInterval: 0.05)
            position = AXElementState.fullValue(scrollBar, cap: 64).flatMap(Double.init)
        }
        if case .object(var object)? = result.data {
            object["position"] = position.map(JSONValue.number) ?? .null
            result.data = .object(object)
        }

        let verification = verify(target: target, beforeVersion: version, before: result.before!,
                                  expectation: .anyChange, timeout: options.timeout)
        let positionMoved: Bool = {
            guard let position, let beforeValue else { return false }
            return abs(position - beforeValue) > 0.001
        }()
        result.changed = verification.changed || positionMoved
        result.verified = normalized != nil
            ? (position.map { abs($0 - targetValue) < 0.01 } ?? false)
            : result.changed
        result.after = verification.after
        result.latencyMS = elapsed(started)
        return result
    }

    /// The vertical scroll bar for a target: itself, a scroll area's
    /// `AXVerticalScrollBar` attribute, or the first vertical descendant.
    private func scrollBarElement(for target: ResolvedTarget) -> AXUIElement? {
        if target.state.role == "AXScrollBar" { return target.element }
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            target.element, "AXVerticalScrollBar" as CFString, &ref
        ) == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            return (ref as! AXUIElement)
        }
        var frontier: [(element: AXUIElement, depth: Int)] = [(target.element, 0)]
        var visited = 0
        while !frontier.isEmpty {
            let (element, depth) = frontier.removeFirst()
            if depth > 0, AXResolver.role(of: element) == "AXScrollBar", isVertical(element) {
                return element
            }
            guard depth < 8 else { continue }
            for child in AXResolver.children(of: element) {
                frontier.append((child, depth + 1))
                visited += 1
                if visited > 800 { return nil }
            }
        }
        return nil
    }

    private func isVertical(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXOrientationAttribute as CFString, &ref) == .success else {
            return true
        }
        return (ref as? String) != "AXHorizontalOrientation"
    }

    // MARK: - Drag

    public func drag(from sourceSpec: TargetSpec, to destinationSpec: TargetSpec) throws -> ActionResult {
        let started = DispatchTime.now()
        try mode.requireSyntheticInput("drag")
        var result = ActionResult(action: "drag")
        let from = try resolve(sourceSpec)
        let to = try resolve(destinationSpec)
        result.target = ActionTargetSummary(entity: from.entity, liveFrame: from.state.frame)
        result.warnings = from.warnings + to.warnings

        guard let fromFrame = from.state.frame, let toFrame = to.state.frame else {
            throw ActionFailure(.invalidArgument, "both drag endpoints need a frame")
        }
        let start = CGPoint(x: fromFrame.midX, y: fromFrame.midY)
        let end = CGPoint(x: toFrame.midX, y: toFrame.midY)
        try guardClickPoint(target: from, point: start, into: &result)
        try guardClickPoint(target: to, point: end, into: &result)

        let version = currentVersion()
        result.before = beforeSnapshot(from, version: version)
        result.method = "cg_drag"
        result.data = .object([
            "from": .string(from.entity.id),
            "to": .string(to.entity.id),
            "start": .numbers([Double(start.x), Double(start.y)]),
            "end": .numbers([Double(end.x), Double(end.y)]),
        ])

        if options.dryRun {
            result.dryRun = true
            result.latencyMS = elapsed(started)
            return result
        }
        InputSynthesizer.drag(from: start, to: end)
        result.attempts.append(ActionAttempt("cg_drag", ok: true,
                                             detail: "\(Int(start.x)),\(Int(start.y)) → \(Int(end.x)),\(Int(end.y))"))
        let verification = verify(target: from, beforeVersion: version, before: result.before!,
                                  expectation: .anyChange, timeout: options.timeout)
        result.changed = verification.changed
        result.verified = verification.verified
        result.after = verification.after
        result.latencyMS = elapsed(started)
        return result
    }

    // MARK: - Menus

    /// Drives the menu bar by path: `["文件", "新建"]`, or indices (`["0", "3"]`)
    /// for menus whose titles are dynamic.
    ///
    /// Menu items only exist in the AX tree while their menu is open, so this is
    /// inherently a multi-step action: open, read, press, descend. Each step is
    /// reported so a failure names the segment that broke.
    public func menu(appKey: String, path: [String]) throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "menu")
        guard !path.isEmpty else {
            throw ActionFailure(.invalidArgument, "--path is required (e.g. \"文件/新建\" or \"0/3\")")
        }
        guard let pid = Self.parsePID(appKey) else {
            throw ActionFailure(.invalidArgument, "app must be pid:NNN (got '\(appKey)')")
        }
        // Menu bars belong to the frontmost app. Background mode will not
        // activate one, so refuse up front — before AX trust and before a
        // dry-run claims the path is actionable.
        if !mode.allowsActivation,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            throw ActionFailure(
                .blockedByPolicy,
                "menu driving requires the app to be frontmost; background mode will not activate it "
                + "(use --mode foreground, or press the menu item's action through its app UI)"
            )
        }
        try ensureTrusted()
        let version = currentVersion()
        result.before = ActionSnapshot(version: version)
        result.method = "ax_menu"

        // Dry run must not touch the desktop at all — activating the app is
        // already a visible side effect, so it comes after this gate.
        if options.dryRun {
            result.dryRun = true
            result.warnings.append("dry run: would drive menu path \(path.joined(separator: " → "))")
            result.latencyMS = elapsed(started)
            return result
        }

        // A background app's menu bar is not the one on screen; in foreground
        // mode bring it forward, exactly like a user would. (Background mode
        // already refused above unless the app was frontmost.)
        if mode.allowsActivation {
            try activateAppPID(pid)
        }

        let resolver = AXResolver(pid: pid)
        guard let menuBar = AXResolver.menuBar(of: resolver.application()) else {
            throw ActionFailure(.notFound, "app pid \(pid) exposes no AXMenuBar subtree")
        }

        var container: AXUIElement = menuBar
        var steps: [JSONValue] = []
        for (index, segment) in path.enumerated() {
            let isLast = index == path.count - 1
            let element = try findMenuElement(in: container, segment: segment, maxDepth: isLast ? 4 : 3)
            let state = AXElementState.read(element)
            let action = state.actions.contains("AXShowMenu")
                ? "AXShowMenu"
                : (state.actions.contains("AXPress") ? "AXPress" : nil)
            guard let action else {
                throw ActionFailure(
                    .actionUnsupported,
                    "menu item '\(segment)' exposes neither AXShowMenu nor AXPress (actions: \(state.actions.joined(separator: ",")))"
                )
            }
            let error = AXUIElementPerformAction(element, action as CFString)
            steps.append(.object([
                "title": .string(segment),
                "method": .string(action),
                "ok": .bool(error == .success),
            ]))
            guard error == .success else {
                throw ActionFailure(
                    .actionUnsupported,
                    "menu press failed at '\(segment)' (AXError \(error.rawValue))"
                )
            }
            if !isLast {
                container = menuContainer(after: element)
            }
        }

        result.data = .object(["path": .array(steps), "app": .string(appKey)])
        result.attempts.append(ActionAttempt("ax_menu", ok: true, detail: path.joined(separator: "/")))
        let observed = options.verify && version != nil
            ? ChangeWaiter.wait(source: source, since: version!, timeout: options.timeout, poll: options.pollInterval)
            : nil
        result.changed = observed != nil
        result.verified = observed != nil
        result.after = ActionSnapshot(version: try? source.version())
        result.latencyMS = elapsed(started)
        return result
    }

    /// Breadth-first, shallow-first match on an exact title (or a child index
    /// when the segment is numeric). Bounded, because a broken AX tree must not
    /// hang an action.
    private func findMenuElement(in container: AXUIElement, segment: String,
                                maxDepth: Int) throws -> AXUIElement {
        if let index = Int(segment) {
            let children = AXResolver.children(of: container)
            guard index >= 0, index < children.count else {
                throw ActionFailure(.notFound,
                                    "menu index \(index) out of range (\(children.count) children)")
            }
            return children[index]
        }

        var frontier: [(element: AXUIElement, depth: Int)] = [(container, 0)]
        var visited = 0
        while !frontier.isEmpty {
            let (element, depth) = frontier.removeFirst()
            if depth > 0, AXResolver.title(of: element) == segment { return element }
            guard depth < maxDepth else { continue }
            for child in AXResolver.children(of: element) {
                frontier.append((child, depth + 1))
                visited += 1
                if visited > 600 {
                    throw ActionFailure(.notFound,
                                        "menu subtree too large while looking for '\(segment)'")
                }
            }
        }
        throw ActionFailure(.notFound, "menu item '\(segment)' not found")
    }

    /// The opened menu lives in the pressed item's AXMenu child, which appears
    /// asynchronously. Falls back to the item itself (some submenus attach
    /// their items directly).
    private func menuContainer(after element: AXUIElement) -> AXUIElement {
        for _ in 0..<6 {
            if let menu = AXResolver.children(of: element)
                .first(where: { AXResolver.role(of: $0) == "AXMenu" }) {
                return menu
            }
            Thread.sleep(forTimeInterval: 0.06)
        }
        return element
    }

    // MARK: - Applications

    public func appAction(_ verb: String, target: String?) throws -> ActionResult {
        let started = DispatchTime.now()
        // Policy precedes permission: refusing to activate is a product rule,
        // not something a missing TCC grant should mask.
        if verb == "activate" {
            try mode.requireActivation("app activate")
        }
        var result = ActionResult(action: "app-\(verb)")
        try ensureTrusted()

        switch verb {
        case "list":
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy != .prohibited }
                .map { app -> JSONValue in
                    .object([
                        "pid": .number(Double(app.processIdentifier)),
                        "bundle": app.bundleIdentifier.map(JSONValue.string) ?? .null,
                        "name": app.localizedName.map(JSONValue.string) ?? .null,
                        "active": .bool(app.isActive),
                        "hidden": .bool(app.isHidden),
                    ])
                }
            result.data = .array(apps)
            result.method = "nsworkspace"
            result.latencyMS = elapsed(started)
            return result

        case "activate", "launch":
            guard let target, !target.isEmpty else {
                throw ActionFailure(.invalidArgument, "app \(verb) needs a pid, bundle id, name or .app path")
            }
            let app: NSRunningApplication
            if verb == "activate" {
                guard let found = resolveRunningApp(target) else {
                    throw ActionFailure(.appNotRunning, "no running application matches '\(target)'")
                }
                app = found
                try activate(app)
            } else {
                app = try launchApp(target, activates: mode.allowsActivation)
            }

            result.method = verb == "launch" ? "nsworkspace_launch" : "nsworkspace_activate"
            if mode.allowsActivation {
                let frontmost = waitUntilFrontmost(app, timeout: options.timeout)
                result.data = .object([
                    "pid": .number(Double(app.processIdentifier)),
                    "bundle": app.bundleIdentifier.map(JSONValue.string) ?? .null,
                    "name": app.localizedName.map(JSONValue.string) ?? .null,
                    "frontmost": .bool(frontmost),
                ])
                result.changed = frontmost
                result.verified = frontmost
                if !frontmost {
                    result.warnings.append("app started but did not become frontmost within \(Int(options.timeout))s")
                }
            } else {
                // Background mode may start an app, but never bring it to the
                // front. Success means "the process is up", not "it is on
                // screen" — reporting frontmost:true here would be a lie.
                let deadline = Date().addingTimeInterval(options.timeout)
                while !app.isFinishedLaunching, !app.isTerminated, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                let running = !app.isTerminated
                result.data = .object([
                    "pid": .number(Double(app.processIdentifier)),
                    "bundle": app.bundleIdentifier.map(JSONValue.string) ?? .null,
                    "name": app.localizedName.map(JSONValue.string) ?? .null,
                    "frontmost": .bool(false),
                ])
                result.changed = running
                result.verified = running && app.isFinishedLaunching
                result.warnings.append("background isolation: launched without activation")
            }
            result.after = ActionSnapshot(version: try? source.version())
            result.latencyMS = elapsed(started)
            return result

        default:
            throw ActionFailure(.invalidArgument, "app verb must be activate|launch|list")
        }
    }

    // MARK: - Clipboard

    public func clipboardAction(_ verb: String, text: String?) throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "clipboard-\(verb)")
        switch verb {
        case "get":
            result.data = ClipboardService.read().map(JSONValue.string) ?? .null
            result.method = "nspasteboard"
        case "set":
            try mode.requireClipboardWrite()
            guard let text else {
                throw ActionFailure(.invalidArgument, "--text is required for clipboard set")
            }
            guard ClipboardService.write(text) else {
                throw ActionFailure(.internalError, "clipboard write failed")
            }
            result.data = .object(["characters": .number(Double(text.count))])
            result.method = "nspasteboard"
        default:
            throw ActionFailure(.invalidArgument, "clipboard verb must be get|set")
        }
        result.latencyMS = elapsed(started)
        return result
    }

    // MARK: - Wait / status

    public func waitForChange(since: UInt64?, timeout: TimeInterval) throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "wait")
        let baseline = since ?? (try? source.version()) ?? 0
        let observed = ChangeWaiter.wait(
            source: source, since: baseline, timeout: timeout, poll: options.pollInterval
        )
        result.changed = observed != nil
        result.verified = observed != nil
        result.data = .object([
            "since": .number(Double(baseline)),
            "version": .number(Double(observed?.version ?? (try? source.version()) ?? baseline)),
            "timed_out": .bool(observed == nil),
        ])
        result.latencyMS = elapsed(started)
        return result
    }

    public func status() throws -> ActionResult {
        let started = DispatchTime.now()
        var result = ActionResult(action: "status")
        let trusted = AXIsProcessTrusted()
        var payload: [String: JSONValue] = [
            "ax_trusted": .bool(trusted),
            "socket": .string(options.socketPath),
            "interaction_mode": .string(mode.rawValue),
        ]
        // Non-interference evidence: before/after comparison of these three
        // values is how an agent (or a test) proves it changed nothing the
        // user shares. All reads are passive.
        if let event = CGEvent(source: nil) {
            payload["cursor"] = .numbers([event.location.x, event.location.y])
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        payload["frontmost_pid"] = frontmost.map {
            .number(Double($0.processIdentifier))
        } ?? .null
        payload["frontmost_name"] = frontmost?.localizedName.map(JSONValue.string) ?? .null
        payload["clipboard_change_count"] = .number(Double(NSPasteboard.general.changeCount))
        if let daemon = try? source.status() {
            payload["daemon_available"] = .bool(true)
            payload["version"] = .number(Double(daemon.version))
            payload["monitored_apps"] = .number(Double(daemon.monitoredApps))
            payload["daemon_permission"] = .bool(daemon.permissionGranted)
            payload["frame_status"] = .string(daemon.frameStatus)
            payload["screen_locked"] = .bool(daemon.screenLocked)
        } else {
            payload["daemon_available"] = .bool(false)
        }
        result.data = .object(payload)
        result.method = "status"
        result.ok = trusted
        if !trusted {
            result.error = ActionError(
                .permissionDenied,
                "Accessibility permission is not granted to this process; gvglact can read frames but cannot act"
            )
        }
        result.latencyMS = elapsed(started)
        return result
    }

    // MARK: - App helpers

    /// Current scroll position when the target itself is a scroll bar (value
    /// 0…1). This is the strong "did we actually move?" signal; the model
    /// version only says *something* changed.
    private func scrollBarValue(_ target: ResolvedTarget) -> Double? {
        guard target.entity.role == "AXScrollBar" else { return nil }
        guard let text = AXElementState.fullValue(target.element, cap: 64) else { return nil }
        return Double(text)
    }

    static func parsePID(_ text: String) -> Int32? {
        if text.hasPrefix("pid:") { return Int32(text.dropFirst(4)) }
        return Int32(text)
    }

    func activateAppPID(_ pid: Int32) throws {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw ActionFailure(.appNotRunning, "no running app for pid \(pid)")
        }
        try activate(app)
        _ = waitUntilFrontmost(app, timeout: options.timeout)
    }

    private func activate(_ app: NSRunningApplication) throws {
        // macOS 14 replaced `activate(options:)` with an API that names the
        // requesting application; our own process is the honest answer.
        let ok: Bool
        if #available(macOS 14.0, *) {
            ok = app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        } else {
            ok = app.activate(options: [.activateAllWindows])
        }
        guard ok else {
            throw ActionFailure(.appNotRunning,
                                "could not activate \(app.localizedName ?? "app")")
        }
    }

    @discardableResult
    private func waitUntilFrontmost(_ app: NSRunningApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private func resolveRunningApp(_ target: String) -> NSRunningApplication? {
        if let pid = Self.parsePID(target) {
            return NSRunningApplication(processIdentifier: pid)
        }
        let running = NSWorkspace.shared.runningApplications
        if let byBundle = running.first(where: { $0.bundleIdentifier == target }) {
            return byBundle
        }
        if let byName = running.first(where: { $0.localizedName == target }) {
            return byName
        }
        return running.first { $0.localizedName?.localizedCaseInsensitiveContains(target) == true }
    }

    private func launchApp(_ target: String, activates: Bool) throws -> NSRunningApplication {
        let url: URL
        if target.hasPrefix("/") {
            url = URL(fileURLWithPath: target)
        } else if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
            url = found
        } else if let byName = resolveRunningApp(target) {
            // Already running: in foreground mode "launch" means "activate"
            // for an app that is up; background mode leaves it where it is.
            if activates { try activate(byName) }
            return byName
        } else {
            throw ActionFailure(.appNotRunning, "no application found for '\(target)'")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        let semaphore = DispatchSemaphore(value: 0)
        var launched: NSRunningApplication?
        var failure: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            launched = app
            failure = error
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 8) == .timedOut {
            throw ActionFailure(.timeout, "launching '\(target)' timed out")
        }
        if let failure {
            throw ActionFailure(.appNotRunning, "launch failed: \(failure.localizedDescription)")
        }
        guard let launched else {
            throw ActionFailure(.appNotRunning, "launch produced no running application")
        }
        return launched
    }
}
