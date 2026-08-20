import SwiftUI
import GVGLCore
import GVGLQuery

/// Display fallback chain for entities whose AXTitle is empty (web static
/// text carries content in value; empty inputs carry placeholder).
func entityDisplayTitle(_ e: Entity) -> String {
    if let title = e.title, !title.isEmpty { return title }
    if let value = e.value, !value.isEmpty { return String(value.prefix(30)) }
    if let placeholder = e.placeholder, !placeholder.isEmpty { return placeholder }
    return e.id
}

/// Selected-entity inspector: every frame field + relation summary, so the
/// V3 capture capabilities (value/state/subrole/zIndex/local space) are
/// directly observable by a human tester.
struct EntityDetailView: View {
    let entity: Entity
    let frame: GVGLFrame
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                badges
                group("标识") {
                    row("ID", entity.id, mono: true)
                    row("应用", "\(entity.appName ?? entity.appID) · pid \(entity.pid)")
                    row("角色", entity.role + (entity.subrole.map { " · \($0)" } ?? ""))
                    if let z = entity.zIndex { row("Z 序", "#\(z)（0=最前）") }
                }
                if entity.value != nil || entity.placeholder != nil {
                    group("内容") {
                        if let value = entity.value { row("value", value) }
                        if let ph = entity.placeholder { row("placeholder", ph) }
                    }
                }
                group("几何") {
                    row("screen", fmt(entity.geometry.screen), mono: true)
                    row("window", fmt(entity.geometry.window), mono: true)
                    row("local", fmt(entity.geometry.local), mono: true)
                    let px = QueryEngine.pixelCenter(of: entity, screen: frame.screen)
                    row("像素中心", "(\(Int(px.x)), \(Int(px.y)))", mono: true)
                }
                if !entity.actions.isEmpty {
                    group("操作") {
                        Text(entity.actions.joined(separator: " · "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                hierarchySection
            }
            .padding(10)
        }
        .frame(width: 280)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entityDisplayTitle(entity))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text(RoleStyle.label(for: entity.role))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var badges: some View {
        HStack(spacing: 6) {
            if entity.focused { badge("焦点", .yellow) }
            if entity.selected { badge("选中", .mint) }
            badge(entity.enabled ? "启用" : "禁用", entity.enabled ? .green : .red)
            if frame.frontmostApp == entity.appID, entity.role == "AXWindow" {
                badge("前台窗口", .blue)
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Text(value)
                .font(mono ? .caption2.monospaced() : .caption2)
                .textSelection(.enabled)
                .lineLimit(4)
            Spacer(minLength: 0)
        }
    }

    private func fmt(_ r: NormRect) -> String {
        String(format: "x %.3f  y %.3f  w %.3f  h %.3f", r.x, r.y, r.w, r.h)
    }

    // MARK: - Hierarchy (V4 scene graph)

    /// Ancestor chain (app root → … → parent) + direct children — the
    /// containment path that flat frames expressed via relations.
    private var hierarchySection: some View {
        let byID = Dictionary(uniqueKeysWithValues: frame.allEntities.map { ($0.id, $0) })
        var chain: [Entity] = []
        var current = entity.entityParentID
        var hops = 0
        while let id = current, hops < 64, let parent = byID[id] {
            chain.insert(parent, at: 0)
            current = parent.entityParentID
            hops += 1
        }
        let kids = entity.children ?? []
        return group("层次") {
            if chain.isEmpty {
                Text("（顶层实体：窗口/菜单栏/孤儿）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(chain, id: \.id) { ancestor in
                    HStack(spacing: 4) {
                        Text("↳")
                            .foregroundStyle(.secondary)
                        Text("\(RoleStyle.label(for: ancestor.role)) · \(entityDisplayTitle(ancestor))")
                            .lineLimit(1)
                    }
                    .font(.caption2)
                }
            }
            if let pruned = entity.prunedChildCount {
                Text("子节点已按 depth 剪枝：\(pruned) 个（去 depth 参数拉取全量）")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if !kids.isEmpty {
                Text("子节点 \(kids.count) 个：")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(kids.prefix(6), id: \.id) { child in
                    HStack(spacing: 4) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text("\(RoleStyle.label(for: child.role)) · \(entityDisplayTitle(child))")
                            .lineLimit(1)
                    }
                    .font(.caption2)
                }
                if kids.count > 6 {
                    Text("… 另 \(kids.count - 6) 个")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
