import Foundation

/// V4 scene graph builder: turns a flat per-app entity list (entityParentID
/// links) into a nested tree. This is a pure re-arrangement — every entity
/// keeps all its V3 fields; containment just becomes structure instead of
/// foreign keys.
public enum SceneTree {
    /// Builds the app's scene roots (windows, menu bar, orphans) with
    /// children attached recursively.
    ///
    /// - Roots: entities whose `entityParentID` is nil or points outside the
    ///   set (parent filtered out by budget caps etc. → orphan joins the root
    ///   level rather than vanishing).
    /// - Order: natural AX order via numeric-aware path comparison
    ///   ("…:0-10" sorts after "…:0-2"; the "mb" menu-bar subtree precedes
    ///   numeric window paths).
    /// - depth: maximum levels below the app root (1 = roots only,
    ///   nil = unlimited). Pruned nodes get `prunedChildCount` and nil
    ///   children, so clients can offer drill-down (`get_frame` without
    ///   depth) without pretending the subtree is empty.
    public static func build(entities: [Entity], depth: Int? = nil) -> [Entity] {
        guard !entities.isEmpty else { return [] }
        let ids = Set(entities.map(\.id))
        var childrenOf: [String: [Entity]] = [:]
        var roots: [Entity] = []
        for e in entities {
            if let parent = e.entityParentID, ids.contains(parent) {
                childrenOf[parent, default: []].append(e)
            } else {
                roots.append(e)
            }
        }

        func attach(_ entity: Entity, level: Int) -> Entity {
            var e = entity
            let kids = childrenOf[e.id] ?? []
            if let depth, level >= depth {
                e.children = nil
                e.prunedChildCount = kids.isEmpty ? nil : kids.count
                return e
            }
            e.children = kids.isEmpty ? nil : kids.sorted { isLess($0.id, $1.id) }.map { attach($0, level: level + 1) }
            return e
        }
        return roots.sorted { isLess($0.id, $1.id) }.map { attach($0, level: 1) }
    }

    /// Depth-first flatten (document order). Nodes keep their `children`
    /// references in memory; the list is a view, not a copy with stripped
    /// links.
    public static func flatten(_ roots: [Entity]) -> [Entity] {
        var out: [Entity] = []
        func visit(_ e: Entity) {
            out.append(e)
            e.children?.forEach(visit)
        }
        roots.forEach(visit)
        return out
    }

    /// Numeric-aware id ordering: compares the path suffix segment-wise
    /// ("pid:1:0-10" > "pid:1:0-2"). Non-numeric segments (the "mb" menu-bar
    /// prefix) sort before numeric ones, so the menu bar leads the roots.
    static func isLess(_ a: String, _ b: String) -> Bool {
        let sa = pathSegments(a)
        let sb = pathSegments(b)
        for i in 0..<min(sa.count, sb.count) {
            let x = sa[i], y = sb[i]
            if x == y { continue }
            switch (Int(x), Int(y)) {
            case let (xi?, yi?): return xi < yi
            case (nil, _?): return true
            case (_?, nil): return false
            default: return x < y
            }
        }
        return sa.count < sb.count
    }

    private static func pathSegments(_ id: String) -> [Substring] {
        let parts = id.split(separator: ":", maxSplits: 2)
        guard parts.count == 3 else { return [] }
        return parts[2].split(separator: "-")
    }
}
