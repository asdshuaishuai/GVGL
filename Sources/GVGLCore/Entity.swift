import Foundation

// MARK: - Entity

public struct Entity: Codable, Hashable, Sendable {
    public var id: String
    public var role: String
    public var title: String?
    public var detail: String?
    public var identifier: String?
    /// AXValue coerced to a short string (≤512 chars): text-field contents,
    /// checkbox/slider state, tab label… nil when the element has no value
    /// or the value duplicates the title (dedup keeps frames lean).
    public var value: String?
    public var subrole: String?
    /// AXFocused — the element currently holding keyboard focus.
    public var focused: Bool
    /// AXSelected — e.g. the selected tab/row.
    public var selected: Bool
    /// AXPlaceholderValue — hint text of empty input fields.
    public var placeholder: String?
    public var enabled: Bool
    public var actions: [String]
    /// AX-tree parent node id (may be a non-entity node such as AXGroup).
    public var axParentID: String?
    /// Nearest ancestor that is itself an entity; the basis of `inside`.
    public var entityParentID: String?
    /// Owning window entity id, if any.
    public var windowID: String?
    /// Owning application key ("pid:NNN").
    public var appID: String
    public var pid: Int32
    /// Owning application display name (localizedName), e.g. "Microsoft Edge".
    public var appName: String?
    /// Physical display this entity lives on (id into screen.displays).
    /// nil when no display matched (falls back to main-display semantics).
    public var displayID: Int?
    /// Global front-to-back rank among on-screen windows (0 = frontmost);
    /// only set on window entities, nil when off-screen/unmatched.
    public var zIndex: Int?
    public var geometry: Geometry
    /// V4 scene graph: child entities when this node is materialized as part
    /// of a scene tree; nil in flat contexts (pipeline output, client-side
    /// flattened lists). Omitted from JSON when nil.
    public var children: [Entity]?
    /// V4: set when a depth-limited frame pruned this node's children
    /// (children then nil; the value is the direct-child count).
    public var prunedChildCount: Int?

    public init(
        id: String,
        role: String,
        title: String?,
        detail: String?,
        identifier: String?,
        value: String? = nil,
        subrole: String? = nil,
        focused: Bool = false,
        selected: Bool = false,
        placeholder: String? = nil,
        enabled: Bool,
        actions: [String],
        axParentID: String?,
        entityParentID: String?,
        windowID: String?,
        appID: String,
        pid: Int32,
        appName: String? = nil,
        displayID: Int? = nil,
        zIndex: Int? = nil,
        geometry: Geometry,
        children: [Entity]? = nil,
        prunedChildCount: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.detail = detail
        self.identifier = identifier
        self.value = value
        self.subrole = subrole
        self.focused = focused
        self.selected = selected
        self.placeholder = placeholder
        self.enabled = enabled
        self.actions = actions
        self.axParentID = axParentID
        self.entityParentID = entityParentID
        self.windowID = windowID
        self.appID = appID
        self.pid = pid
        self.appName = appName
        self.displayID = displayID
        self.zIndex = zIndex
        self.geometry = geometry
        self.children = children
        self.prunedChildCount = prunedChildCount
    }

    enum CodingKeys: String, CodingKey {
        case id, role, title, detail, identifier, value, subrole, focused, selected
        case placeholder, enabled, actions, axParentID, entityParentID, windowID
        case appID, pid, appName, displayID, zIndex, geometry, children, prunedChildCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        // V3 fields: absent in pre-expansion frames → safe defaults.
        value = try c.decodeIfPresent(String.self, forKey: .value)
        subrole = try c.decodeIfPresent(String.self, forKey: .subrole)
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        actions = try c.decode([String].self, forKey: .actions)
        axParentID = try c.decodeIfPresent(String.self, forKey: .axParentID)
        entityParentID = try c.decodeIfPresent(String.self, forKey: .entityParentID)
        windowID = try c.decodeIfPresent(String.self, forKey: .windowID)
        appID = try c.decode(String.self, forKey: .appID)
        pid = try c.decode(Int32.self, forKey: .pid)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        displayID = try c.decodeIfPresent(Int.self, forKey: .displayID)
        zIndex = try c.decodeIfPresent(Int.self, forKey: .zIndex)
        geometry = try c.decode(Geometry.self, forKey: .geometry)
        children = try c.decodeIfPresent([Entity].self, forKey: .children)
        prunedChildCount = try c.decodeIfPresent(Int.self, forKey: .prunedChildCount)
    }
}

public extension Entity {
    /// Convenience initializer without app-name/display info (legacy call sites).
    init(
        id: String,
        role: String,
        title: String?,
        detail: String?,
        identifier: String?,
        enabled: Bool,
        actions: [String],
        axParentID: String?,
        entityParentID: String?,
        windowID: String?,
        appID: String,
        pid: Int32,
        geometry: Geometry
    ) {
        self.init(
            id: id, role: role, title: title, detail: detail, identifier: identifier,
            enabled: enabled, actions: actions, axParentID: axParentID,
            entityParentID: entityParentID, windowID: windowID, appID: appID,
            pid: pid, appName: nil, displayID: nil, geometry: geometry
        )
    }
}

