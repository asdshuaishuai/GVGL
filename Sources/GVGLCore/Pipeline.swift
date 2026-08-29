import Foundation

public struct PipelineOutput: Hashable, Sendable {
    public var entities: [Entity]
    public var relations: [Relation]
    public var index: SpatialIndex
    /// V2-3 CGWindow cross-check stats (0/0/[] when no probe data).
    public var cgWindowCount: Int
    public var axWindowCount: Int
    public var missingWindowTitles: [String]

    public static let empty = PipelineOutput(
        entities: [], relations: [], index: SpatialIndex(),
        cgWindowCount: 0, axWindowCount: 0, missingWindowTitles: []
    )

    public init(
        entities: [Entity],
        relations: [Relation],
        index: SpatialIndex,
        cgWindowCount: Int = 0,
        axWindowCount: Int = 0,
        missingWindowTitles: [String] = []
    ) {
        self.entities = entities
        self.relations = relations
        self.index = index
        self.cgWindowCount = cgWindowCount
        self.axWindowCount = axWindowCount
        self.missingWindowTitles = missingWindowTitles
    }
}

/// Converts one app's AX snapshot into normalized entities, relations and index.
public final class Pipeline: @unchecked Sendable {
    public let screen: ScreenInfo
    /// Minimum physical area (px^2) for an element to become an entity.
    public var minArea: Double
    public var interactiveRoles: Set<String>
    /// Replaceable index builder (V2-1): grid by default, linear-scan for V1
    /// compatibility, any future strategy behind the same seam.
    public var indexBuilder: SpatialIndexBuilding
    /// Whether to compute the O(N²) relation set (direction/near/aligned).
    /// V4 frames no longer serialize relations (clients compute them
    /// geometrically on demand), so the daemon passes false to save the CPU;
    /// tests and direct Pipeline consumers keep the default true.
    public var computeRelations: Bool

    public static let defaultInteractiveRoles: Set<String> = [
        // V1 原始 13 种
        "AXButton", "AXTextField", "AXCheckBox", "AXRadioButton",
        "AXMenu", "AXMenuItem", "AXLink", "AXComboBox", "AXSlider",
        "AXStepper", "AXWindow", "AXImage", "AXStaticText",
        // V3 扩充：输入
        "AXTextArea", "AXSecureTextField",
        // 按钮/开合
        "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle",
        // 标签页与工具栏（AI 桌面核心交互面）
        "AXTabGroup", "AXTab", "AXToolbar",
        // 列表/表格/大纲结构与可点行
        "AXList", "AXOutline", "AXTable", "AXRow", "AXCell",
        // 窗口级容器与地标
        "AXSheet", "AXDrawer", "AXHeading",
        // 菜单栏（挂在应用 AXMenuBar 属性下，不在 AXChildren 遍历路径上）
        "AXMenuBar", "AXMenuBarItem",
        // 状态与布局调节
        "AXProgressIndicator", "AXSplitter",
    ]

    public init(
        screen: ScreenInfo,
        minArea: Double = 1.0,
        interactiveRoles: Set<String> = Pipeline.defaultInteractiveRoles,
        gridSize: Int = 0,
        computeRelations: Bool = true
    ) {
        self.screen = screen
        self.minArea = minArea
        self.interactiveRoles = interactiveRoles
        self.indexBuilder = GridIndexBuilder(gridSize: gridSize)
        self.computeRelations = computeRelations
    }

    public func process(_ snapshot: AXAppSnapshot) -> PipelineOutput {
        let coords = CoordinateComputer(screen: screen)
        let flat = flatten(snapshot.nodes)
        // Electron-class apps mutate their tree mid-walk often enough that the
        // same path can be visited twice; uniqueKeysWithValues would trap the
        // whole daemon on the first occurrence. First visit wins.
        let nodeByID = Dictionary(flat.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Rule 1-3: role whitelist + drop group-like roles + drop degenerate frames.
        var entities: [Entity] = []
        var emitted = Set<String>()
        emitted.reserveCapacity(flat.count)
        for node in flat {
            guard let role = node.role, interactiveRoles.contains(role) else { continue }
            guard !["AXGroup", "AXScrollArea", "AXClipView"].contains(role) else { continue }
            guard let frame = node.frame, frame.width > 0, frame.height > 0,
                  frame.width * frame.height >= minArea else { continue }
            // Duplicate path (tree mutated mid-walk): first visit wins, so the
            // entity set — and every downstream id-keyed consumer — stays unique.
            guard emitted.insert(node.id).inserted else { continue }

            // Screen Space = main-display normalization (original doc §2.2
            // 转换1: screen_norm.x = x / screenW). displayID is informational
            // metadata only — it never changes the coordinate semantics.
            // V5 Display Space: per-display normalization of the SAME pixel
            // rect; region labels derive from it (quadrants correct on every
            // display).
            let display = displayFor(rect: frame)
            let screenRect = coords.screenNorm(frame)
            let displayRect = display.map { coords.displayNorm(frame, display: $0) } ?? screenRect
            let windowRect = windowNormRect(for: node, nodeByID: nodeByID, coords: coords, screenRect: screenRect)
            let geometry = Geometry(screen: screenRect, window: windowRect, display: displayRect)

            let entity = Entity(
                id: node.id,
                role: role,
                title: node.title,
                detail: node.detail,
                identifier: node.identifier,
                // Dedup: StaticText & friends often expose the same string as
                // both AXTitle and AXValue; storing both doubles the payload
                // on dense pages for zero information gain.
                value: (node.value == node.title) ? nil : node.value,
                subrole: node.subrole,
                focused: node.focused,
                selected: node.selected,
                placeholder: node.placeholder,
                enabled: node.enabled,
                actions: node.actions,
                axParentID: node.parentID,
                entityParentID: nil,
                windowID: node.windowID,
                appID: snapshot.appKey,
                pid: snapshot.pid,
                appName: snapshot.appName,
                displayID: display?.id,
                geometry: geometry
            )
            entities.append(entity)
        }

        // Rule 4: nearest entity ancestor (basis of inside/contains).
        let entityIDs = Set(entities.map(\.id))
        for i in entities.indices {
            entities[i].entityParentID = nearestEntityAncestor(
                of: entities[i], nodeByID: nodeByID, entityIDs: entityIDs
            )
        }

        // Rule 5: local space — the entity's rect in its nearest entity
        // ancestor's coordinate system (V3). Resolution-independent: both
        // rects are in screen space, so the ratio cancels the display size.
        // Entities without an entity parent keep the unit rect.
        let entityByID = Dictionary(entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for i in entities.indices {
            guard let parentID = entities[i].entityParentID,
                  let parent = entityByID[parentID] else { continue }
            let p = parent.geometry.screen
            guard !p.isEmpty else { continue }
            let s = entities[i].geometry.screen
            entities[i].geometry.local = NormRect(
                x: (s.x - p.x) / p.w,
                y: (s.y - p.y) / p.h,
                w: s.w / p.w,
                h: s.h / p.h
            )
        }

        // V3: global window z-order from the CG probe (front-to-back rank).
        assignZOrder(entities: &entities, cgWindows: snapshot.cgWindows)

        let relations = computeRelations ? TopologyComputer().compute(entities: entities) : []
        let index = indexBuilder.build(from: entities)

        let windowStats = crossCheckWindows(entities: entities, snapshot: snapshot)

        return PipelineOutput(
            entities: entities.sorted { $0.id < $1.id },
            relations: relations,
            index: index,
            cgWindowCount: windowStats.cgCount,
            axWindowCount: windowStats.axCount,
            missingWindowTitles: windowStats.missing
        )
    }

    // MARK: - V2-3 CGWindow cross-check

    private func crossCheckWindows(entities: [Entity], snapshot: AXAppSnapshot)
        -> (cgCount: Int, axCount: Int, missing: [String]) {
        let windows = entities.filter { $0.role == "AXWindow" }
        let axCount = windows.count
        // Diagnostics are opt-in (--cg-check); z-order above is always on.
        guard snapshot.cgDiagnosticsEnabled else {
            return (0, axCount, [])
        }
        let cgWindows = snapshot.cgWindows
        guard !cgWindows.isEmpty else {
            return (0, axCount, [])
        }
        var missing: [String] = []
        for cg in cgWindows {
            let center = CGPoint(x: cg.bounds.midX, y: cg.bounds.midY)
            let matched = windows.contains { entity in
                let px = pixelCenter(of: entity)
                let dx = px.x - center.x, dy = px.y - center.y
                return dx * dx + dy * dy < 24 * 24
            }
            if !matched {
                missing.append(cg.name?.isEmpty == false ? cg.name! : "untitled-\(cg.id)")
            }
        }
        return (cgWindows.count, axCount, missing)
    }

    // MARK: - V3 window z-order

    /// Stamps each window entity with the global front-to-back rank of its
    /// matching CG window (center proximity, same 24px rule as the V2-3
    /// cross-check). Off-screen windows (other Spaces, minimized) keep nil.
    private func assignZOrder(entities: inout [Entity], cgWindows: [CGWindowInfo]) {
        guard !cgWindows.isEmpty else { return }
        var claimed = Set<UInt32>()
        for i in entities.indices where entities[i].role == "AXWindow" {
            let px = pixelCenter(of: entities[i])
            var best: CGWindowInfo?
            var bestDist = Double.greatestFiniteMagnitude
            for cg in cgWindows where !claimed.contains(cg.id) {
                let dx = px.x - cg.bounds.midX, dy = px.y - cg.bounds.midY
                let d2 = dx * dx + dy * dy
                if d2 < bestDist { bestDist = d2; best = cg }
            }
            guard let best, bestDist < 24 * 24 else { continue }
            entities[i].zIndex = best.zIndex
            claimed.insert(best.id)
        }
    }

    /// Inverse of `screenNorm`: screen space is main-display-normalized
    /// (rect / mainScreen), so the exact inverse is center * mainScreen —
    /// never mix in per-display origins/sizes, which would double-offset
    /// secondary-display elements and break CG matching there.
    private func pixelCenter(of entity: Entity) -> CGPoint {
        CGPoint(
            x: entity.geometry.centerX * screen.width,
            y: entity.geometry.centerY * screen.height
        )
    }

    // MARK: - Helpers

    private func flatten(_ nodes: [AXNode]) -> [AXNode] {
        var result: [AXNode] = []
        func visit(_ n: AXNode) {
            result.append(n)
            for c in n.children { visit(c) }
        }
        for n in nodes { visit(n) }
        return result
    }

    private func windowNormRect(
        for node: AXNode,
        nodeByID: [String: AXNode],
        coords: CoordinateComputer,
        screenRect: NormRect
    ) -> NormRect {
        guard let windowID = node.windowID else { return screenRect }
        if windowID == node.id {
            // The entity is itself a window: relative to itself → unit rect.
            return .unit
        }
        guard let windowNode = nodeByID[windowID],
              let windowFrame = windowNode.frame,
              windowFrame.width > 0, windowFrame.height > 0 else {
            return screenRect
        }
        let winRect = coords.screenNorm(windowFrame)
        return coords.windowNorm(screenRect, window: winRect)
    }

    /// Physical display containing the rect's center; falls back to the first
    /// (main) display. nil when the screen carries no display info.
    private func displayFor(rect: CGRect) -> DisplayInfo? {
        guard !screen.displays.isEmpty else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return screen.displays.first(where: { $0.contains(center) }) ?? screen.displays.first
    }

    private func nearestEntityAncestor(
        of entity: Entity,
        nodeByID: [String: AXNode],
        entityIDs: Set<String>
    ) -> String? {
        var current = entity.axParentID
        var hops = 0
        while let id = current, hops < 64 {
            if entityIDs.contains(id) { return id }
            current = nodeByID[id]?.parentID
            hops += 1
        }
        return nil
    }
}
