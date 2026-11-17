import Foundation

// MARK: - Spatial labels

/// Four quadrants, computed from the entity center in Display Space (V5:
/// per-display quadrants — the space a human sees the element in).
public enum Region: String, Codable, Hashable, Sendable, CaseIterable {
    case q1, q2, q3, q4

    public static func of(centerX: Double, centerY: Double) -> Region {
        if centerY < 0.5 {
            return centerX < 0.5 ? .q1 : .q2
        }
        return centerX < 0.5 ? .q3 : .q4
    }
}

/// Nine-grid cell, computed from the entity center in Display Space (V5).
public enum Region9: String, Codable, Hashable, Sendable, CaseIterable {
    case leftTop, centerTop, rightTop
    case leftCenter, centerCenter, rightCenter
    case leftBottom, centerBottom, rightBottom

    public static func of(centerX: Double, centerY: Double) -> Region9 {
        let hz: Region9
        if centerX < 1.0 / 3.0 {
            hz = .leftTop
        } else if centerX < 2.0 / 3.0 {
            hz = .centerTop
        } else {
            hz = .rightTop
        }
        if centerY < 1.0 / 3.0 {
            return hz
        } else if centerY < 2.0 / 3.0 {
            return Region9(rawValue: hz.rawValue.replacingOccurrences(of: "Top", with: "Center"))!
        }
        return Region9(rawValue: hz.rawValue.replacingOccurrences(of: "Top", with: "Bottom"))!
    }
}

