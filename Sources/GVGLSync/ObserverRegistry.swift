import ApplicationServices
import Foundation

/// Registers per-app AXObservers on a dedicated runloop thread and forwards
/// notifications to a handler. Window-level notifications carry the window's
/// current rect so the engine can do per-window subtree captures; app-level
/// notifications (window created) pass nil.
public final class ObserverRegistry: @unchecked Sendable {
    public typealias NotificationHandler = (Int32, CGRect?) -> Void

    private final class Box {
        let pid: Int32
        let registry: ObserverRegistry
        init(pid: Int32, registry: ObserverRegistry) {
            self.pid = pid
            self.registry = registry
        }
        func notify(_ notification: String, element: AXUIElement) {
            registry.handle(pid: pid, notification: notification, element: element)
        }
    }

    private let handler: NotificationHandler
    private let worker = ObserverWorker()
    private let lock = NSLock()
    private var observers: [Int32: AXObserver] = [:]
    private var boxes: [Int32: Box] = [:]
    private var registeredWindows: [Int32: [AXUIElement]] = [:]
    /// The focused element per app that carries value-change observations
    /// (focus-follow: exactly one element per app at a time).
    /// Mutated only on the observer thread.
    private var valueObservedElements: [Int32: AXUIElement] = [:]

    public init(handler: @escaping NotificationHandler) {
        self.handler = handler
        worker.start()
    }

    public func startMonitoring(pid: Int32) {
        worker.submit { [weak self] in self?.register(pid: pid) }
    }

    public func stopMonitoring(pid: Int32) {
        worker.submit { [weak self] in self?.unregister(pid: pid) }
    }

    // MARK: - Registration (runs on the observer thread)

    private func register(pid: Int32) {
        lock.lock()
        guard observers[pid] == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let box = Box(pid: pid, registry: self)
        let refcon = Unmanaged.passUnretained(box).toOpaque()

        var obs: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &obs) == .success, let obs else { return }

        for name in Self.appNotifications {
            AXObserverAddNotification(obs, app, name as CFString, refcon)
        }

        let windows = fetchWindows(app: app)
        for w in windows {
            addWindowNotifications(obs, window: w, refcon: refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .commonModes)

        lock.lock()
        observers[pid] = obs
        boxes[pid] = box
        registeredWindows[pid] = windows
        lock.unlock()
    }

    private func unregister(pid: Int32) {
        lock.lock()
        let obs = observers.removeValue(forKey: pid)
        let windows = registeredWindows.removeValue(forKey: pid) ?? []
        let box = boxes.removeValue(forKey: pid)
        let focused = valueObservedElements.removeValue(forKey: pid)
        lock.unlock()

        guard let obs else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .commonModes)
        for w in windows {
            for name in Self.windowNotifications {
                AXObserverRemoveNotification(obs, w, name as CFString)
            }
        }
        if let focused {
            for name in Self.valueNotifications {
                AXObserverRemoveNotification(obs, focused, name as CFString)
            }
        }
        _ = box // dropped once the observer is dead
    }

    private func handle(pid: Int32, notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification as String:
            refreshWindows(pid: pid)
            handler(pid, nil)
        case kAXFocusedUIElementChangedNotification as String:
            // Focus-follow: move value observation to the newly focused element.
            followFocus(pid: pid, element: element)
            fallthrough
        case kAXValueChangedNotification as String, kAXSelectedTextChangedNotification as String:
            // Element-level event: the subtree capture needs the WINDOW rect,
            // not the element's (window matching is by window center).
            if let window = Self.windowAncestor(of: element) {
                handler(pid, elementRect(window))
            } else {
                handler(pid, nil)
            }
        case kAXMenuOpenedNotification as String, kAXMenuClosedNotification as String:
            // Menus can live outside any window (menu bar) → full capture.
            handler(pid, nil)
        default:
            // Window-level notifications (moved/resized/destroyed/title/
            // miniaturized/deminiaturized/sheet/drawer): element IS the window.
            handler(pid, elementRect(element))
        }
    }

    /// Move value/selected-text observation to the focused element (one per
    /// app): typing, toggling and text selection then become event-driven.
    /// Called on the observer thread.
    private func followFocus(pid: Int32, element: AXUIElement) {
        lock.lock()
        let obs = observers[pid]
        let box = boxes[pid]
        let previous = valueObservedElements[pid]
        lock.unlock()
        guard let obs, let box else { return }
        if let previous, CFEqual(previous, element) { return }

        if let previous {
            for name in Self.valueNotifications {
                AXObserverRemoveNotification(obs, previous, name as CFString)
            }
        }
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        for name in Self.valueNotifications {
            AXObserverAddNotification(obs, element, name as CFString, refcon)
        }
        lock.lock()
        valueObservedElements[pid] = element
        lock.unlock()
    }

    /// Walk up the AX parent chain to the containing window (element-level
    /// notifications carry the element, but subtree capture keys on windows).
    static func windowAncestor(of element: AXUIElement, maxHops: Int = 64) -> AXUIElement? {
        var current: AXUIElement? = element
        var hops = 0
        while let node = current, hops < maxHops {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleRef) == .success,
               (roleRef as? String) == kAXWindowRole {
                return node
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef, CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { return nil }
            current = (parentRef as! AXUIElement)
            hops += 1
        }
        return nil
    }

    private func elementRect(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        guard let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        if AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &pos),
           AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size),
           size.width > 0, size.height > 0 {
            return CGRect(origin: pos, size: size)
        }
        return nil
    }

    /// New windows need their own move/resize observers; re-register on creation.
    private func refreshWindows(pid: Int32) {
        worker.submit { [weak self] in self?.reRegisterWindows(pid: pid) }
    }

    private func reRegisterWindows(pid: Int32) {
        lock.lock()
        guard let obs = observers[pid], let box = boxes[pid] else {
            lock.unlock()
            return
        }
        let known = registeredWindows[pid] ?? []
        lock.unlock()

        let app = AXUIElementCreateApplication(pid)
        let windows = fetchWindows(app: app)
        let refcon = Unmanaged.passUnretained(box).toOpaque()

        // AXUIElement fetches always return fresh CF objects, so identity
        // (`===`) never matches across fetches; CFEqual compares the
        // underlying AX tokens (pid + element id) and is the stable test.
        let added = windows.filter { w in !known.contains(where: { CFEqual($0, w) }) }
        let removed = known.filter { k in !windows.contains(where: { CFEqual($0, k) }) }

        for w in removed {
            for name in Self.windowNotifications {
                AXObserverRemoveNotification(obs, w, name as CFString)
            }
        }
        for w in added {
            addWindowNotifications(obs, window: w, refcon: refcon)
        }

        lock.lock()
        // Replace (never append): the set tracks current windows only, so
        // destroyed windows can't accumulate stale entries.
        registeredWindows[pid] = windows
        lock.unlock()
    }

    private func addWindowNotifications(_ obs: AXObserver, window: AXUIElement, refcon: UnsafeMutableRawPointer) {
        for name in Self.windowNotifications {
            AXObserverAddNotification(obs, window, name as CFString, refcon)
        }
    }

    private func fetchWindows(app: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == CFArrayGetTypeID() else { return [] }
        let array = ref as! [AnyObject]
        return array.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    // MARK: - Callback

    /// Window-level: registered on every known window (re-registered on
    /// creation). Sheet/drawer arrive on the window they attach to.
    private static let windowNotifications = [
        "AXWindowMoved", "AXWindowResized", "AXUIElementDestroyed", "AXTitleChanged",
        "AXWindowMiniaturized", "AXWindowDeminiaturized",
        "AXSheetCreated", "AXDrawerCreated",
    ]

    /// App-level: registered once on the application element. Focus/main-window
    /// moves and menu open/close are posted by the app.
    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedUIElementChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXMenuOpenedNotification,
        kAXMenuClosedNotification,
    ]

    /// Element-level: registered ONLY on the focused element (focus-follow) —
    /// registering these on every element would swamp the AX channel.
    private static let valueNotifications = [
        kAXValueChangedNotification,
        kAXSelectedTextChangedNotification,
    ]

    private static let axCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
        box.notify(notification as String, element: element)
    }
}

/// Dedicated thread with a live CFRunLoop; all AXObserver work happens here so
/// callbacks always fire on the same thread the sources were added to.
private final class ObserverWorker {
    private let ready = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "gvgl.axobserver.work")
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    func start() {
        thread = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = CFRunLoopGetCurrent()
            RunLoop.current.add(Port(), forMode: .default)
            // Keep the runloop alive even when no observer sources exist,
            // so CFRunLoopRunInMode below never spins on an empty mode.
            Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in }
            self.ready.signal()
            while true {
                CFRunLoopRunInMode(.defaultMode, 10, false)
            }
        }
        thread?.name = "gvgl.axobserver"
        thread?.start()
        ready.wait()
    }

    func submit(_ block: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self, let runLoop = self.runLoop else { return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
            CFRunLoopWakeUp(runLoop)
        }
    }
}
