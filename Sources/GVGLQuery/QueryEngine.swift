import CoreGraphics
import Foundation
import GVGLCore

/// Query parameters (design doc §6.1).
public struct QueryParams: Equatable, Hashable {
    public var role: String?
    public var label: String?
    public var region: String?
    public var app: String?
    public var refID: String?
    public var refDir: String?
    public var top: Int

    public init(role: String? = nil, label: String? = nil, region: String? = nil,
                app: String? = nil, refID: String? = nil, refDir: String? = nil,
                top: Int = 5) {
        self.role = role
        self.label = label
        self.region = region
        self.app = app
        self.refID = refID
        self.refDir = refDir
        self.top = top
    }
}

public struct ScoredEntity: Identifiable, Hashable {
    public let id: String
    public let entity: Entity
    public let score: Double
    public let breakdown: [String: Double]

    public init(id: String, entity: Entity, score: Double, breakdown: [String: Double]) {
        self.id = id
        self.entity = entity
        self.score = score
        self.breakdown = breakdown
    }
}

public enum QueryStatus: String {
    case hit
    case ambiguous
    case notFound
    case axWeak
}

public struct QueryResult: Hashable {
    public let status: QueryStatus
    public let ranked: [ScoredEntity]
    public let best: ScoredEntity?
    /// Title-less element summaries for the ax_weak path (§4.3).
    public let weakElements: [Entity]

    public init(status: QueryStatus, ranked: [ScoredEntity], best: ScoredEntity?, weakElements: [Entity]) {
        self.status = status
        self.ranked = ranked
        self.best = best
        self.weakElements = weakElements
    }
}

/// Local multi-dimensional scoring per the design doc §6.2, mirroring
/// client/gvgl_query.py exactly (weights and thresholds).
public enum QueryEngine {
    public static let weights: (semantic: Double, role: Double, spatial: Double, size: Double, topology: Double) =
        (0.35, 0.20, 0.25, 0.10, 0.10)

    public static let compatibleRoles: [String: Set<String>] = [
        "AXButton": ["AXButton", "AXMenuItem"],
        "AXMenuItem": ["AXMenuItem", "AXButton"],
        "AXCheckBox": ["AXCheckBox", "AXRadioButton"],
        "AXRadioButton": ["AXRadioButton", "AXCheckBox"],
        "AXTextField": ["AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox"],
        "AXTextArea": ["AXTextArea", "AXTextField"],
        "AXSecureTextField": ["AXSecureTextField", "AXTextField"],
        "AXComboBox": ["AXComboBox", "AXTextField", "AXPopUpButton"],
        "AXPopUpButton": ["AXPopUpButton", "AXComboBox"],
    ]

    public struct RelationKey: Hashable {
        public let type: String
        public let from: String
        public let to: String
        public init(type: String, from: String, to: String) {
            self.type = type
            self.from = from
            self.to = to
        }
    }

    public static func relationKeys(_ relations: [Relation]) -> Set<RelationKey> {
        Set(relations.map { RelationKey(type: $0.type.rawValue, from: $0.from, to: $0.to) })
    }

    public static func query(frame: GVGLFrame, params: QueryParams) -> QueryResult {
        let entities: [Entity] = params.app.map { app in
            frame.allEntities.filter { $0.appID == app }
        } ?? frame.allEntities
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })

        var candidates = entities
        if let region = params.region {
            let regionSet = Set(frame.index.byRegion[region] ?? [])
            candidates = candidates.filter { regionSet.contains($0.id) }
        }

        let refEntity = params.refID.flatMap { byID[$0] }
        let refRegion = refEntity?.geometry.region.rawValue

        var scored: [ScoredEntity] = []
        for e in candidates {
            let (score, breakdown) = score(entity: e, params: params, ref: refEntity, refRegion: refRegion, byID: byID)
            scored.append(ScoredEntity(id: e.id, entity: e, score: score, breakdown: breakdown))
        }
        scored.sort { $0.score > $1.score }
        let topN = Array(scored.prefix(max(1, params.top)))

        // Confidence gates (§6.3): ≥0.7 hit / 0.4~0.7 ambiguous / <0.4 not_found
        // / ax_weak when role-matched elements exist but carry no usable titles.
        var status: QueryStatus
        var weak: [Entity] = []
        if let best = topN.first {
            if best.score >= 0.7 {
                status = .hit
            } else if best.score >= 0.4 {
                status = .ambiguous
            } else {
                status = .notFound
                weak = weakAXSummary(topN)
                if !weak.isEmpty, topN.allSatisfy({ $0.breakdown["semantic"] == 0 }) {
                    status = .axWeak
                }
            }
        } else {
            status = .notFound
        }

        return QueryResult(status: status, ranked: topN, best: topN.first, weakElements: weak)
    }

    public static func score(entity: Entity, params: QueryParams,
                             ref: Entity?, refRegion: String?,
                             byID: [String: Entity]) -> (score: Double, breakdown: [String: Double]) {
        var semantic = 0.0
        if let label = params.label {
            let title = entity.title ?? ""
            if title == label {
                semantic = 1.0
            } else if title.contains(label) {
                semantic = 0.7
            } else if (entity.placeholder ?? "").contains(label) {
                semantic = 0.65
            } else if (entity.detail ?? "").contains(label) {
                semantic = 0.6
            } else if (entity.value ?? "").contains(label) {
                semantic = 0.55
            } else if (entity.identifier ?? "").contains(label) {
                semantic = 0.5
            }
        }

        var roleScore = 0.0
        if let role = params.role {
            if entity.role == role {
                roleScore = 1.0
            } else if compatibleRoles[entity.role]?.contains(role) == true {
                roleScore = 0.6
            }
        }

        var spatial = 0.0
        if let ref {
            if let refDir = params.refDir {
                spatial = spatialScore(entity, ref: ref, dir: refDir, byID: byID)
            } else if entity.id == ref.id {
                spatial = 1.0
            }
        }

        let area = entity.geometry.area
        let size: Double
        if area >= 0.001 && area <= 0.05 {
            size = 1.0
        } else if area >= 0.0005 && area <= 0.1 {
            size = 0.6
        } else {
            size = 0.2
        }

        var topology = 0.0
        if entity.windowID != nil { topology += 0.3 }
        if entity.enabled { topology += 0.3 }
        if !entity.actions.isEmpty { topology += 0.4 }

        let total = semantic * weights.semantic
            + roleScore * weights.role
            + spatial * weights.spatial
            + size * weights.size
            + topology * weights.topology
        return (total, [
            "semantic": semantic, "role": roleScore, "spatial": spatial,
            "size": size, "topology": topology,
        ])
    }

    /// §4.3 ax_weak: role-matched elements with no usable title/identifier.
    /// A non-empty value counts as usable text (V3): web static text often
    /// carries its content in AXValue while the title stays empty.
    public static func weakAXSummary(_ scored: [ScoredEntity]) -> [Entity] {
        scored.compactMap { s in
            let e = s.entity
            let title = e.title ?? ""
            let detail = e.detail ?? ""
            let identifier = e.identifier ?? ""
            let value = e.value ?? ""
            let placeholder = e.placeholder ?? ""
            guard title.isEmpty, detail.isEmpty, identifier.isEmpty,
                  value.isEmpty, placeholder.isEmpty else { return nil }
            return e
        }
    }

    /// V4: spatial relation scoring computed geometrically on demand — same
    /// rules as TopologyComputer (direction / near / same-quadrant), but only
    /// for query candidates. No O(N²) frame payload, no truncation caps, and
    /// cross-window pairs are judged in screen space (previously impossible:
    /// stored direction relations were same-window only).
    static func spatialScore(_ e: Entity, ref: Entity, dir: String, byID: [String: Entity]) -> Double {
        let sameWindow = e.windowID != nil && e.windowID == ref.windowID
        let a = sameWindow ? e.geometry.window : e.geometry.screen
        let b = sameWindow ? ref.geometry.window : ref.geometry.screen
        let normalized = dir.replacingOccurrences(of: "-", with: "").lowercased()

        let dx = a.centerX - b.centerX
        let dy = a.centerY - b.centerY
        let isNear = (dx * dx + dy * dy).squareRoot() < TopologyComputer.nearThreshold

        if normalized == "near" {
            if isNear { return 1.0 }
            return e.geometry.region == ref.geometry.region ? 0.5 : 0
        }

        // R12: containment prunes the direction tier (near stays reachable).
        let contained = isAncestor(e, of: ref, byID: byID) || isAncestor(ref, of: e, byID: byID)
        if !contained {
            let satisfied: Bool
            switch normalized {
            case "rightof": satisfied = a.x > b.x + b.w
            case "leftof": satisfied = a.x + a.w < b.x
            case "above": satisfied = a.y + a.h < b.y
            case "below": satisfied = a.y > b.y + b.h
            default: satisfied = false
            }
            if satisfied { return 1.0 }
        }
        if isNear { return 0.7 }
        return e.geometry.region == ref.geometry.region ? 0.5 : 0
    }

    /// Walks entityParentID links (kept on every node, flat or tree) to test
    /// ancestry. Bounded like the pipeline's own ancestor walk.
    static func isAncestor(_ ancestor: Entity, of descendant: Entity, byID: [String: Entity]) -> Bool {
        var current = descendant.entityParentID
        var hops = 0
        while let id = current, hops < 64 {
            if id == ancestor.id { return true }
            current = byID[id]?.entityParentID
            hops += 1
        }
        return false
    }

    /// Global Quartz pixel center (original doc 转换3: centerX * screenW).
    public static func pixelCenter(of entity: Entity, screen: ScreenInfo) -> CGPoint {
        CGPoint(x: entity.geometry.centerX * screen.width,
                y: entity.geometry.centerY * screen.height)
    }
}
