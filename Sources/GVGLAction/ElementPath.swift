import Foundation

/// Entity IDs are AX element paths produced by `Snapshotter.makeID`:
///
///   "pid:722:root"      the application element itself
///   "pid:722:0-2-3"     AXChildren[0] → [2] → [3], starting at the app element
///   "pid:722:mb"        the app's AXMenuBar element
///   "pid:722:mb-1-0"    AXMenuBar's AXChildren[1] → [0]
///
/// The grammar is a contract between the snapshotter (producer), scene-tree
/// ordering, per-window subtree merge and — since actions are addressed by ID —
/// whoever turns an ID back into a live AXUIElement. Keeping the parse in one
/// place is what stops those consumers from disagreeing about, say, whether
/// "mb" is a numeric segment.
public struct ElementPath: Hashable, Sendable {
    public enum Root: String, Hashable, Sendable {
        /// The application element (`AXUIElementCreateApplication`).
        case application
        /// The app's `AXMenuBar` attribute subtree — not reachable via
        /// AXChildren, and never owned by a window.
        case menuBar
    }

    /// "pid:NNN" — the same key frames use for `appID` / `SceneApp.appKey`.
    public var appKey: String
    public var root: Root
    /// Child indices from the root, outermost first. Empty = the root itself.
    public var indices: [Int]

    public init(appKey: String, root: Root = .application, indices: [Int] = []) {
        self.appKey = appKey
        self.root = root
        self.indices = indices
    }

    /// "pid:NNN" → NNN. nil when the app key is not a process key (synthetic
    /// clients may build ids with other prefixes; those are not resolvable).
    public var pid: Int32? {
        guard appKey.hasPrefix("pid:") else { return nil }
        return Int32(appKey.dropFirst(4))
    }

    /// True when the id addresses a root rather than a child.
    public var isRoot: Bool { indices.isEmpty }

    /// Reconstructs the canonical id string for this path.
    public var id: String {
        let suffix: String
        if root == .menuBar {
            suffix = indices.isEmpty ? "mb" : "mb-" + indices.map(String.init).joined(separator: "-")
        } else {
            suffix = indices.isEmpty ? "root" : indices.map(String.init).joined(separator: "-")
        }
        return "\(appKey):\(suffix)"
    }

    public static func parse(_ id: String) -> ElementPath? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let appKey = "\(parts[0]):\(parts[1])"
        let suffix = parts[2]
        guard !suffix.isEmpty else { return nil }

        if suffix == "root" {
            return ElementPath(appKey: appKey, root: .application)
        }
        if suffix == "mb" {
            return ElementPath(appKey: appKey, root: .menuBar)
        }
        if suffix.hasPrefix("mb-") {
            guard let indices = parseIndices(suffix.dropFirst(3)) else { return nil }
            return ElementPath(appKey: appKey, root: .menuBar, indices: indices)
        }
        guard let indices = parseIndices(suffix) else { return nil }
        return ElementPath(appKey: appKey, root: .application, indices: indices)
    }

    /// "0-2-3" → [0, 2, 3]. Rejects empty segments, negatives and non-numbers,
    /// so a stabilized/heuristic id that is not a real path is never mistaken
    /// for one (the window merge relies on this to reject namespace matches).
    private static func parseIndices(_ text: Substring) -> [Int]? {
        guard !text.isEmpty else { return nil }
        var result: [Int] = []
        for segment in text.split(separator: "-", omittingEmptySubsequences: false) {
            guard let value = Int(segment), value >= 0 else { return nil }
            result.append(value)
        }
        return result
    }

    /// True when `other` lives inside this path's subtree (prefix match on
    /// indices, same app and root).
    public func isAncestor(of other: ElementPath) -> Bool {
        guard appKey == other.appKey, root == other.root else { return false }
        guard other.indices.count >= indices.count else { return false }
        return zip(indices, other.indices).allSatisfy(==)
    }
}
