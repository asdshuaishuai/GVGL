import CoreGraphics
import Foundation

/// One on-screen CG window (from CGWindowList, Quartz top-left coordinates).
public struct CGWindowInfo: Hashable, Sendable {
    public var id: UInt32
    public var name: String?
    public var bounds: CGRect
    public var layer: Int
    /// Global front-to-back rank among ALL on-screen windows (0 = frontmost).
    /// CGWindowList returns windows in z-order; the rank survives the per-pid
    /// filter so windows of different apps stay comparable.
    public var zIndex: Int

    public init(id: UInt32, name: String?, bounds: CGRect, layer: Int, zIndex: Int = 0) {
        self.id = id
        self.name = name
        self.bounds = bounds
        self.layer = layer
        self.zIndex = zIndex
    }
}

public protocol CGWindowProviding: Sendable {
    /// On-screen windows owned by `pid` (current Space, optionOnScreenOnly).
    func onScreenWindows(pid: Int32) -> [CGWindowInfo]
    /// Processes that own at least one clickable on-screen window, whether or
    /// not NSWorkspace knows them as applications.
    ///
    /// NSWorkspace only surfaces *bundled* applications. A process without an
    /// app bundle can still own a perfectly readable AX window — the standard
    /// `osascript -e 'display dialog ...'` modal is the common case, and so are
    /// some CLI/TUI and helper processes. Those were previously invisible to
    /// the daemon, so an agent asking for a button inside a dialog got
    /// confident-but-wrong answers derived from unrelated windows.
    ///
    /// The caller diffs this against what it already tracks, both to pick up
    /// new processes and to notice when a discovered one has gone away.
    func discoverWindowOwnerPIDs() -> [Int32]
}

/// Real CGWindowList probe. Used as a SECOND data source for window-level
/// cross-validation (V2-3) and always-on z-order ranking (V3: CGWindowList
/// is a cheap local call with no target-app IPC; AX stays the geometry
/// source of record).
public struct CGWindowProbe: CGWindowProviding {
    public init() {}

    public func onScreenWindows(pid: Int32) -> [CGWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [CGWindowInfo] = []
        // The list is ordered front-to-back: the enumeration index IS the
        // global z-rank (kept global so ranks are comparable across apps).
        for (index, w) in list.enumerated() {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
            guard let boundsDict = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let width = boundsDict["Width"], let height = boundsDict["Height"],
                  width > 0, height > 0 else { continue }
            result.append(CGWindowInfo(
                id: (w[kCGWindowNumber as String] as? UInt32) ?? 0,
                name: w[kCGWindowName as String] as? String,
                bounds: CGRect(x: x, y: y, width: width, height: height),
                layer: (w[kCGWindowLayer as String] as? Int) ?? 0,
                zIndex: index
            ))
        }
        return result
    }

    /// Layers that represent a window a person can actually click.
    ///
    /// 0 is normal windows, 3 floating, 8 is where standard modal panels
    /// (`display dialog`) actually land — a layer-0-only filter misses exactly
    /// the dialogs this method exists to find. 20 is the Dock. The menu bar
    /// (24/25) and the negative system layers (wallpaper, Notification Centre,
    /// WindowManager) are deliberately excluded: they are not clickable
    /// targets and are already covered by NSWorkspace app discovery.
    private static let discoverableLayerRange = 0...20

    /// Ignore specks so a one-pixel helper surface does not pull in a process
    /// nobody could ever click.
    private static let minimumClickableSize: CGFloat = 40

    public func discoverWindowOwnerPIDs() -> [Int32] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var owners: Set<Int32> = []
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32 else { continue }
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            guard Self.discoverableLayerRange.contains(layer) else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], let height = b["Height"],
                  width >= Self.minimumClickableSize, height >= Self.minimumClickableSize
            else { continue }
            owners.insert(pid)
        }
        return owners.sorted()
    }
}
