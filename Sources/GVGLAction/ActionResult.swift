import Foundation
import GVGLCore

/// A JSON value with no schema, used for command-specific payloads (find
/// results, text reads, menu steps) inside the one stable result envelope.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public static func numbers(_ values: [Double]) -> JSONValue {
        .array(values.map { .number($0) })
    }
}

/// Stable error codes. Clients branch on these; messages are for humans and
/// may change.
public enum ActionErrorCode: String, Codable, Sendable {
    case notFound = "not_found"
    case staleReference = "stale_reference"
    case targetObscured = "target_obscured"
    case actionUnsupported = "action_unsupported"
    case ambiguousMatch = "ambiguous_match"
    case focusFailed = "focus_failed"
    case permissionDenied = "permission_denied"
    case timeout
    case invalidArgument = "invalid_argument"
    case appNotRunning = "app_not_running"
    case blockedByPolicy = "blocked_by_policy"
    case verificationFailed = "verification_failed"
    case internalError = "internal_error"
}

public struct ActionError: Codable, Hashable, Sendable {
    public var code: ActionErrorCode
    public var message: String

    public init(_ code: ActionErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// The element an action was aimed at, in the coordinates an agent needs to
/// reason about it (live pixel rect, not the possibly-stale frame rect).
public struct ActionTargetSummary: Codable, Hashable, Sendable {
    public var id: String
    public var role: String
    public var title: String?
    public var app: String
    public var rect: PixelRect?

    public init(entity: Entity, liveFrame: CGRect? = nil) {
        self.id = entity.id
        self.role = entity.role
        self.title = entity.title
        self.app = entity.appID
        self.rect = liveFrame.map(PixelRect.init)
    }
}

public struct ActionSnapshot: Codable, Hashable, Sendable {
    public var version: UInt64?
    public var element: ElementSnapshot?
    public var focusedID: String?
    public var changedApps: [String]

    public init(version: UInt64? = nil, element: ElementSnapshot? = nil,
                focusedID: String? = nil, changedApps: [String] = []) {
        self.version = version
        self.element = element
        self.focusedID = focusedID
        self.changedApps = changedApps
    }
}

public struct ActionAttempt: Codable, Hashable, Sendable {
    public var method: String
    public var ok: Bool
    public var detail: String?

    public init(_ method: String, ok: Bool, detail: String? = nil) {
        self.method = method
        self.ok = ok
        self.detail = detail
    }
}

/// One response shape for every command — actions, queries, reads.
///
/// `ok` means the requested operation was executed (and, when verification was
/// possible, observed to take effect). `changed` means the desktop observably
/// reacted; `verified` means the change matched the expectation for this verb.
/// They are deliberately separate: a click that produced no visible change is
/// not a failure, but an agent needs to know it happened.
public struct ActionResult: Codable, Sendable {
    public var ok: Bool
    public var action: String
    public var target: ActionTargetSummary?
    public var method: String?
    /// Which interaction policy this action ran under. Present on every CLI
    /// result so an audit can tell "semantic only" from "may have touched the
    /// shared input path" without inferring it from the method name.
    public var isolation: InteractionMode?
    public var dryRun: Bool
    public var latencyMS: Int
    public var changed: Bool
    public var verified: Bool
    public var before: ActionSnapshot?
    public var after: ActionSnapshot?
    public var attempts: [ActionAttempt]
    public var warnings: [String]
    public var data: JSONValue?
    public var error: ActionError?

    public init(action: String) {
        self.ok = true
        self.action = action
        self.target = nil
        self.method = nil
        self.isolation = nil
        self.dryRun = false
        self.latencyMS = 0
        self.changed = false
        self.verified = false
        self.before = nil
        self.after = nil
        self.attempts = []
        self.warnings = []
        self.data = nil
        self.error = nil
    }

    public static func failure(_ action: String, _ error: ActionError,
                               latencyMS: Int = 0) -> ActionResult {
        var result = ActionResult(action: action)
        result.ok = false
        result.error = error
        result.latencyMS = latencyMS
        return result
    }

    public var summaryLine: String {
        if let error {
            return "\(action): \(error.code.rawValue) — \(error.message)"
        }
        let changedText = changed ? "changed" : "no observable change"
        return "\(action): ok via \(method ?? "?") (\(changedText), \(latencyMS)ms)"
    }
}
