import AppKit
import SwiftUI
import GVGLCore
import GVGLQuery

/// 单一 GVGL 应用：审查台窗口 + 菜单栏监控 + 内嵌守护进程助手。
@main
struct GVGLApp: App {
    @StateObject private var console = DesktopViewModel()
    @StateObject private var monitor = MonitorModel()

    var body: some Scene {
        WindowGroup("GVGL 审查台", id: "console") {
            ContentView()
                .environmentObject(console)
                .onAppear { console.reconnect() }
        }
        .defaultSize(width: 1360, height: 860)

        MenuBarExtra {
            MonitorMenuView()
                .environmentObject(monitor)
        } label: {
            Label("GVGL", systemImage: monitor.connected ? "network" : "network.slash")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: DesktopViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Label(model.connected ? "GVGL 已连接" : "GVGL 未连接",
                          systemImage: model.connected ? "network" : "network.slash")
                        .foregroundStyle(model.connected ? .green : .red)
                    TextField("socket 路径", text: $model.socketPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    Button("连接", action: model.reconnect)
                        .buttonStyle(.bordered)
                    if let frame = model.frame {
                        Text("v\(frame.version) · \(frame.status.rawValue) · \(frame.allEntities.count) 实体")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let error = model.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)

                HStack(spacing: 8) {
                    DesktopCanvasView(frame: model.frame,
                                      selectedID: model.selectedID,
                                      onSelect: { model.select($0) })
                    if let selected = model.selectedEntity, let frame = model.frame {
                        EntityDetailView(entity: selected, frame: frame,
                                         onClose: { model.select(nil) })
                    }
                }

                CommandPanelView(model: model)
                    .frame(height: 210)
            }
            .padding(8)
        }
        .navigationTitle("GVGL — 几何虚拟桌面")
    }
}
