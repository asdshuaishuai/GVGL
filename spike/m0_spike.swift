import Cocoa
import ApplicationServices
import CoreGraphics

let trusted = AXIsProcessTrusted()
print("AXIsProcessTrusted: \(trusted)")
if !trusted {
    print("HINT: grant Accessibility permission to the host app (Terminal/iTerm) in System Settings > Privacy & Security > Accessibility")
}

guard let frontApp = NSWorkspace.shared.frontmostApplication else {
    print("No frontmost application")
    exit(1)
}
let pid = frontApp.processIdentifier
let appName = frontApp.localizedName ?? "?"
print("Frontmost: \(appName) pid=\(pid) bundle=\(frontApp.bundleIdentifier ?? "?")")

// --- Screen geometry: Cocoa vs Quartz ---
if let screen = NSScreen.main {
    print("NSScreen.main.frame(origin=\(screen.frame.origin), size=\(screen.frame.size))  // Cocoa, bottom-left origin")
}
let display = CGMainDisplayID()
let bounds = CGDisplayBounds(display)
print("CGDisplayBounds: \(bounds)  // Quartz, top-left origin")
let scale = CGDisplayPixelsWide(display) / Int(bounds.width)
print("scaleFactor: \(scale)")

// --- AX windows vs CGWindowList ---
let axApp = AXUIElementCreateApplication(pid)
var windowsRef: CFTypeRef?
let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
guard err == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
    print("AX windows error: \(err.rawValue)")
    exit(1)
}
print("AX windows: \(windows.count)")

let winInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let cgWins = winInfo.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
print("CG windows (on screen): \(cgWins.count)")

for (i, win) in windows.prefix(3).enumerated() {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    var titleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
    AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
    AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
    var pos = CGPoint.zero
    var size = CGSize.zero
    if let posRef, CFGetTypeID(posRef) == AXValueGetTypeID() {
        let posVal = unsafeBitCast(posRef, to: AXValue.self)
        if AXValueGetType(posVal) == .cgPoint {
            AXValueGetValue(posVal, .cgPoint, &pos)
        }
    }
    if let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
        let sizeVal = unsafeBitCast(sizeRef, to: AXValue.self)
        if AXValueGetType(sizeVal) == .cgSize {
            AXValueGetValue(sizeVal, .cgSize, &size)
        }
    }
    let title = titleRef as? String ?? "(nil)"
    print("AX win[\(i)] pos=(\(pos.x), \(pos.y)) size=(\(size.width), \(size.height)) title=\(title)")
    if let cgMatch = cgWins.first(where: { ($0[kCGWindowName as String] as? String) == title }),
       let boundsDict = cgMatch[kCGWindowBounds as String] as? [String: CGFloat] {
        let bx = boundsDict["X"] ?? 0
        let by = boundsDict["Y"] ?? 0
        let bw = boundsDict["Width"] ?? 0
        let bh = boundsDict["Height"] ?? 0
        print("  CG   win     bounds=(\(bx), \(by)) size=(\(bw), \(bh))")
        print("  delta x=\(pos.x - bx) y=\(pos.y - by)  <- y==0 means SAME origin as Quartz (top-left, NO flip needed)")
    }
}

// --- AXObserver: window moved notification ---
final class SpikeCtx {
    var count = 0
    var last = ""
}
let ctx = SpikeCtx()

let callback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let c = Unmanaged<SpikeCtx>.fromOpaque(refcon).takeUnretainedValue()
    var titleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
    print("  NOTIFY [\(notification as String)] title=\(titleRef as? String ?? "(?)")")
    c.count += 1
    c.last = notification as String
}

var obs: AXObserver?
let obErr = AXObserverCreate(pid, callback, &obs)
guard obErr == .success, let obs, let mainWin = windows.first else {
    print("AXObserverCreate failed: \(obErr.rawValue)")
    exit(1)
}
let refconPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(ctx).toOpaque())
let addErr1 = AXObserverAddNotification(obs, mainWin, kAXWindowMovedNotification as CFString, refconPtr)
let addErr2 = AXObserverAddNotification(obs, mainWin, kAXWindowResizedNotification as CFString, refconPtr)
print("add Moved=\(addErr1.rawValue) Resized=\(addErr2.rawValue) (0 == success)")
CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
print(">>> Move or resize a window of '\(appName)' within 8 seconds ...")
RunLoop.main.run(until: Date(timeIntervalSinceNow: 8))
print("Notifications received: \(ctx.count) last=\(ctx.last)")
