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
}
