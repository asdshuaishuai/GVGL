import Foundation

/// Heuristic element-ID stabilization across full re-captures.
///
/// IDs are path-based ("pid:NNN:0-3-7"); when the AX tree shifts (an element is
/// inserted above another), every descendant's path changes and naive IDs would
/// all churn on the next reconcile. To keep references stable for clients,
/// before applying a re-capture we try to match each new entity to a unique old
/// entity (same role, same owning window, same title/identifier, near-identical
/// window-space position) and reuse the old ID.
///
/// IDs are opaque tokens — reusing an old id for an entity whose tree path
/// changed is intentional.
public enum IDStabilizer {
    /// Position tolerance in normalized space: two captures of the same element
    /// rarely shift more than this (layout changes are the exception).
    public static let positionTolerance = 0.05
    /// Windows match by screen-space proximity instead of window-space (window
    /// space is always the unit rect for window entities).
    public static let windowPositionTolerance = 0.05

    /// Returns new-id -> old-id map. Only unambiguous matches are reused; any
    /// ambiguous or unmatched new entity keeps its path-based id.
    public static func stabilize(old: [Entity], new: [Entity]) -> [String: String] {
        guard !old.isEmpty, !new.isEmpty else { return [:] }

        let oldByWindow = Dictionary(grouping: old) { key(for: $0) }
        var used = Set<String>()
        var map: [String: String] = [:]

        for n in new {
            let candidates = oldByWindow[key(for: n)] ?? []
            guard !candidates.isEmpty else { continue }

            var matched: Entity?
            // Prefer strong matches: non-empty equal title or identifier.
            let strong = candidates.filter { c in
                !used.contains(c.id) && strongMatch(c, n)
            }
            if let best = nearest(strong, to: n), let picked = uniqueMatch(strong, nearest: best, for: n) {
                matched = picked
            } else {
                // Fallback: positional-only match for titleless elements.
                let positional = candidates.filter { c in !used.contains(c.id) && positionClose(c, n) }
                if positional.count == 1 {
                    matched = positional[0]
                }
            }
            // Only record actual re-keys; id → same-id mappings are noise.
            if let matched, matched.id != n.id {
                map[n.id] = matched.id
                used.insert(matched.id)
            }
        }
        return map
    }

    private static func key(for e: Entity) -> String {
        "\(e.role)|\(e.windowID ?? "")|\(e.appID)"
    }

    private static func strongMatch(_ old: Entity, _ new: Entity) -> Bool {
        if let t1 = old.title, let t2 = new.title, !t1.isEmpty, !t2.isEmpty, t1 == t2 {
            return true
        }
        if let i1 = old.identifier, let i2 = new.identifier, !i1.isEmpty, !i2.isEmpty, i1 == i2 {
            return true
        }
        return false
    }

    /// With multiple strong candidates, pick the one whose position matches and
    /// require it to be unambiguous among strong candidates.
    private static func uniqueMatch(_ strong: [Entity], nearest best: Entity, for new: Entity) -> Entity? {
        let positionMatches = strong.filter { positionClose($0, new) }
        guard positionMatches.count == 1, positionMatches[0].id == best.id else { return nil }
        return best
    }

    private static func nearest(_ candidates: [Entity], to new: Entity) -> Entity? {
        candidates.min { distanceSquared($0, new) < distanceSquared($1, new) }
    }

    private static func distanceSquared(_ a: Entity, _ b: Entity) -> Double {
        let ra = positionRect(a), rb = positionRect(b)
        let dx = ra.centerX - rb.centerX
        let dy = ra.centerY - rb.centerY
        return dx * dx + dy * dy
    }

    private static func positionClose(_ a: Entity, _ b: Entity) -> Bool {
        let ra = positionRect(a), rb = positionRect(b)
        let dx = ra.centerX - rb.centerX
        let dy = ra.centerY - rb.centerY
        return (dx * dx + dy * dy).squareRoot() < positionTolerance
    }

    private static func positionRect(_ e: Entity) -> NormRect {
        e.role == kAXWindowRole ? e.geometry.screen : e.geometry.window
    }
}

public extension PipelineOutput {
    /// Rewrites entity/relation ids and rebuilds the index after stabilization.
    func remapped(by map: [String: String]) -> PipelineOutput {
        guard !map.isEmpty else { return self }
        let newIDs = Set(map.keys)

        let remapID: (String?) -> String? = { id in
            guard let id, newIDs.contains(id) else { return id }
            return map[id]
        }

        let remappedEntities = entities.map { e in
            var e = e
            if let mapped = map[e.id] {
                e.id = mapped
            }
            e.entityParentID = remapID(e.entityParentID)
            e.windowID = remapID(e.windowID)
            return e
        }

        // Remap is a pure re-keying: every entity pre-remap exists, so every
        // relation endpoint resolves to a live entity after remapping.
        let remappedRelations = relations.map { r in
            Relation(
                type: r.type,
                from: remapID(r.from) ?? r.from,
                to: remapID(r.to) ?? r.to,
                distance: r.distance
            )
        }

        return PipelineOutput(
            entities: remappedEntities,
            relations: remappedRelations,
            index: SpatialIndex.build(from: remappedEntities),
            // CG cross-check stats survive re-keying (previously dropped).
            cgWindowCount: cgWindowCount,
            axWindowCount: axWindowCount,
            missingWindowTitles: missingWindowTitles
        )
    }
}
