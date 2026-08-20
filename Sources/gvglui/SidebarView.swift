import SwiftUI
import GVGLCore

/// Sidebar: daemon status + app/entity list with filters.
struct SidebarView: View {
    @ObservedObject var model: DesktopViewModel

    @State private var roleFilter: String = "全部"
    @State private var labelFilter: String = ""
    @State private var appFilter: String = "全部"

    var body: some View {
        List {
            Section("守护进程") {
                Label(model.connected ? "已连接" : "未连接",
                      systemImage: model.connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.connected ? .green : .red)
                if let status = model.status {
                    Text("App 监控: \(status["monitored_apps"] as? Int ?? 0)")
                    Text("version: \(status["version"] as? UInt64 ?? 0)")
                }
                if !model.connected {
                    Button("启动守护进程") { model.startDaemon() }
                        .buttonStyle(.borderedProminent)
                }
                Toggle("自动跟随", isOn: $model.autoWatch)
                Toggle("允许执行点击", isOn: $model.allowExecute)
                    .help("开启后可在结果面板直接点击真实桌面")
                Button("刷新") { model.refresh() }
                    .buttonStyle(.bordered)
            }

            Section("筛选") {
                Picker("角色", selection: $roleFilter) {
                    Text("全部").tag("全部")
                    // Roles are discovered from the live frame (V3 expanded
                    // the whitelist; a hardcoded list would hide new roles).
                    ForEach(availableRoles, id: \.self) { role in
                        Text(RoleStyle.label(for: role)).tag(role)
                    }
                }
                .onChange(of: availableRoles) { _, roles in
                    if roleFilter != "全部", !roles.contains(roleFilter) {
                        roleFilter = "全部"
                    }
                }
                TextField("标题/value/ID 过滤", text: $labelFilter)
                    .textFieldStyle(.roundedBorder)
                Picker("App", selection: $appFilter) {
                    Text("全部").tag("全部")
                    if let frame = model.frame {
                        ForEach(frame.scene.map(\.appKey), id: \.self) { app in
                            Text("\(appName(for: app)) (\(app))").tag(app)
                        }
                    }
                }
            }

            Section("事件流 (\(model.events.count))") {
                if model.events.isEmpty {
                    Text("等待帧变化（移动窗口/输入/切换焦点试试）…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                ForEach(model.events.prefix(15)) { event in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(event.time, format: .dateTime.hour().minute().second())
                            Text("v\(event.version)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption2.monospacedDigit())
                        Text(event.changedApps.map { appName(for: $0) }.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 1)
                }
            }

            Section("应用概览 (\(appSummaries.count))") {
                ForEach(appSummaries, id: \.appKey) { summary in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(summary.name)
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text("\(summary.entityCount) 实体")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if !summary.windows.isEmpty {
                            Text(summary.windows.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("实体 (\(filteredEntities.count))") {
                ForEach(filteredEntities.prefix(500), id: \.id) { e in
                    Button {
                        model.select(e.id)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(RoleStyle.color(for: e.role))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entityDisplayTitle(e))
                                    .font(.callout)
                                    .foregroundStyle(e.id == model.selectedID ? Color.accentColor : .primary)
                                Text("\(e.appName ?? appName(for: e.appID)) · \(e.role) · \(e.id)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// App display name from the frame's scene app nodes.
    private func appName(for appID: String) -> String {
        guard let frame = model.frame else { return appID }
        return frame.scene.first { $0.appKey == appID }?.name ?? appID
    }

    /// Per-app summary straight from the scene roots: display name + entity
    /// count + window titles (windows are top-level children of the app node).
    private var appSummaries: [AppSummary] {
        guard let frame = model.frame else { return [] }
        return frame.scene.map { app in
            AppSummary(
                appKey: app.appKey,
                name: app.name ?? app.appKey,
                entityCount: app.entityCount,
                windows: app.children
                    .filter { $0.role == "AXWindow" }
                    .compactMap { $0.title?.isEmpty == false ? $0.title : nil }
            )
        }
        .filter { $0.entityCount > 0 }
    }

    private struct AppSummary {
        let appKey: String
        let name: String
        let entityCount: Int
        let windows: [String]
    }

    private var filteredEntities: [Entity] {
        guard let frame = model.frame else { return [] }
        return frame.allEntities.filter { e in
            if roleFilter != "全部" && e.role != roleFilter { return false }
            if appFilter != "全部" && e.appID != appFilter { return false }
            if !labelFilter.isEmpty {
                let needle = labelFilter.lowercased()
                let title = (e.title ?? "").lowercased()
                let id = e.id.lowercased()
                let value = (e.value ?? "").lowercased()
                guard title.contains(needle) || id.contains(needle) || value.contains(needle) else { return false }
            }
            return true
        }
        .sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    /// Roles actually present in the current frame, sorted.
    private var availableRoles: [String] {
        guard let frame = model.frame else { return [] }
        return frame.allEntities.reduce(into: Set<String>()) { $0.insert($1.role) }.sorted()
    }
}
