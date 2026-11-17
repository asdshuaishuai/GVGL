import Foundation
import GVGLCore

/// Per-window subtree merge: replace only the entities of `windowID` with the
/// freshly captured subtree; every other window keeps its previous entities
/// byte-identical.
///
/// The keep-filter is three-way, not just `windowID != windowID`: a subtree
/// re-capture also re-produces entities of nested windows (sheets, drawers,
/// Electron inner AXWindows) whose `windowID` points at the nested window —
/// filtering on the top-level id alone left them in `keep` and the merged set
/// ended up with the same path id twice (V4.1 #1: 20 duplicate ids in one
/// ZCode/Electron frame).
///
/// 1. exact subtree ids (deterministic path-derived ids),
/// 2. the captured window's path namespace (covers budget-truncated
///    re-captures that produced fewer ids than the previous sweep),
/// 3. the legacy windowID equality,
/// and the final id-dedup keeps the first occurrence.
public enum WindowSubtreeMerge {
    public static func merge(previous: PipelineOutput, subtree: PipelineOutput,
                             windowID: String) -> PipelineOutput {
        let subtreeIDs = Set(subtree.entities.map(\.id))
        let keep = previous.entities.filter { e in
            !subtreeIDs.contains(e.id) && !isInSubtreeNamespace(e.id, of: windowID) && e.windowID != windowID
        }
        let entities = (keep + subtree.entities).sorted { $0.id < $1.id }
        return PipelineOutput(
            entities: entities,
            cgWindowCount: previous.cgWindowCount,
            axWindowCount: previous.axWindowCount,
            missingWindowTitles: previous.missingWindowTitles
        )
    }

    /// True when `id` is `windowID` itself or a path-descendant of it
    /// ("pid:7:0-2" owns "pid:7:0-2-3-1"). Non-path ids (stabilized drift,
    /// "mb" menu-bar ids) are never in the namespace, and neither is another
    /// app's same-shaped path: the namespace is per-process.
    public static func isInSubtreeNamespace(_ id: String, of windowID: String) -> Bool {
        guard let entityPath = numericPath(from: id),
              let windowPath = numericPath(from: windowID) else { return false }
        guard entityPath.count >= windowPath.count else { return false }
        let idParts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        let windowParts = windowID.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard idParts.prefix(2) == windowParts.prefix(2) else { return false }
        return zip(entityPath, windowPath).allSatisfy(==)
    }

    /// "pid:722:0-2-3" → [0, 2, 3]; nil for ids without a numeric path suffix.
    public static func numericPath(from id: String) -> [Int]? {
        guard let suffix = id.split(separator: ":", maxSplits: 2).last else { return nil }
        let parts = suffix.split(separator: "-").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == suffix.split(separator: "-").count else { return nil }
        return parts
    }
}

/// The capture throttle as a pure predicate: skip if recently captured, or
/// cooling down after an error/slow capture. Separated from SyncEngine's lock
/// so the boundary cases (notification storm, wedged app) are unit-testable
/// without waiting on real clocks.
public enum CaptureGate {
    public static func shouldCapture(now: Date, lastCaptured: Date?, cooldownUntil: Date?,
                                     minInterval: TimeInterval, cooldownOnError: TimeInterval) -> Bool {
        if let cooldownUntil, cooldownUntil > now { return false }
        if let lastCaptured, now.timeIntervalSince(lastCaptured) < minInterval { return false }
        return true
    }
}
