import Foundation

/// Computes spatial relations among entities, applying the pruning rules (R12).
///
/// Per the original design doc §2.5/§3.1:
/// - 3.1 inside/contains derived from the entity tree (no geometry needed).
/// - 3.2 above/below/left-of/right-of: geometry within the same parent window
///   (all pairs; no distance cut).
/// - 3.3 near: ALL pairs, Euclidean distance < 0.05.
/// - 3.4 aligned: ALL pairs, |dy| < min(h)*0.5 (row) or |dx| < min(w)*0.5 (col).
/// - R12: canonical direction only (above(A,B) ⇒ no below(B,A)); inside prunes
///   all direction relations for that pair.
///
/// Protective deviation (evidence-based, documented in DESIGN.md): hard output
/// caps (`maxRelationsPerGroup`/`maxRelationsTotal`) — without them a dense web
/// page (thousands of AXStaticText in one window) produces millions of
/// relations and a frame of hundreds of MB.
public struct TopologyComputer: Sendable {
    public static let nearThreshold = 0.05
    public static let nearThresholdSquared = nearThreshold * nearThreshold
    /// Per relation-group cap for direction/aligned.
    public var maxRelationsPerGroup: Int = 500
    /// Global cap across all relations (except inside/contains, which stay
    /// small by construction).
    public var maxRelationsTotal: Int = 5000

    public init() {}

    public func compute(entities: [Entity]) -> [Relation] {
        var relations: [Relation] = []
        var seen = Set<String>()

        func add(_ r: Relation) {
            let key = "\(r.type.rawValue)|\(r.from)|\(r.to)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            relations.append(r)
        }

        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })

        // 3.1 inside / contains from the entity tree.
        for e in entities {
            if let parentID = e.entityParentID, byID[parentID] != nil {
                add(Relation(type: .inside, from: e.id, to: parentID))
                add(Relation(type: .contains, from: parentID, to: e.id))
            }
        }

        // 3.2 direction + aligned within the same window (all pairs).
        let grouped = Dictionary(grouping: entities, by: groupKey)
        for group in grouped.values {
            var groupCount = 0
            for i in 0..<group.count {
                guard relations.count < maxRelationsTotal else { break }
                let a = group[i]
                guard let ra = byID[a.id]?.geometry.window else { continue }
                for j in (i + 1)..<group.count {
                    guard groupCount < maxRelationsPerGroup,
                          relations.count < maxRelationsTotal else { break }
                    let b = group[j]
                    guard let rb = byID[b.id]?.geometry.window else { continue }
                    guard ra.isEmpty == false, rb.isEmpty == false else { continue }
                    // R12: inside prunes direction relations for the pair.
                    guard a.entityParentID != b.id, b.entityParentID != a.id else { continue }

                    let aBottom = ra.y + ra.h
                    let aRight = ra.x + ra.w
                    let bBottom = rb.y + rb.h
                    let bRight = rb.x + rb.w

                    if aBottom < rb.y {
                        add(Relation(type: .above, from: a.id, to: b.id))
                        groupCount += 1
                    } else if ra.y > bBottom {
                        add(Relation(type: .below, from: a.id, to: b.id))
                        groupCount += 1
                    } else if aRight < rb.x {
                        add(Relation(type: .leftOf, from: a.id, to: b.id))
                        groupCount += 1
                    } else if ra.x > bRight {
                        add(Relation(type: .rightOf, from: a.id, to: b.id))
                        groupCount += 1
                    }

                    if isAligned(a: ra, b: rb) {
                        add(Relation(type: .aligned, from: a.id, to: b.id))
                        groupCount += 1
                    }
                }
            }
        }

        // 3.3 near + 3.4 aligned over ALL pairs (window space within a window,
        // screen space across windows).
        for i in 0..<entities.count {
            guard relations.count < maxRelationsTotal else { break }
            let a = entities[i]
            for j in (i + 1)..<entities.count {
                guard relations.count < maxRelationsTotal else { break }
                let b = entities[j]
                let sameWindow = a.windowID != nil && a.windowID == b.windowID
                guard let ra = sameWindow ? byID[a.id]?.geometry.window : byID[a.id]?.geometry.screen,
                      let rb = sameWindow ? byID[b.id]?.geometry.window : byID[b.id]?.geometry.screen else { continue }
                guard ra.isEmpty == false, rb.isEmpty == false else { continue }

                let dx = ra.centerX - rb.centerX
                let dy = ra.centerY - rb.centerY
                if dx * dx + dy * dy < Self.nearThresholdSquared {
                    add(Relation(type: .near, from: a.id, to: b.id, distance: (dx * dx + dy * dy).squareRoot()))
                }
                // Same-window aligned already emitted in the group pass.
                if !sameWindow && isAligned(a: ra, b: rb) {
                    add(Relation(type: .aligned, from: a.id, to: b.id))
                }
            }
        }

        return relations.sorted { ($0.from, $0.type.rawValue, $0.to) < ($1.from, $1.type.rawValue, $1.to) }
    }

    private func groupKey(_ e: Entity) -> String {
        if e.role == kAXWindowRole {
            return "app:\(e.appID)"
        }
        return e.windowID ?? "app:\(e.appID)"
    }

    private func isAligned(a: NormRect, b: NormRect) -> Bool {
        // Horizontal alignment (same row): row centers within half the smaller height.
        let hAlign = abs(a.centerY - b.centerY) < min(a.h, b.h) * 0.5
        // Vertical alignment (same column): column centers within half the smaller width.
        let vAlign = abs(a.centerX - b.centerX) < min(a.w, b.w) * 0.5
        return hAlign || vAlign
    }
}

public let kAXWindowRole = "AXWindow"
