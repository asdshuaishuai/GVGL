import SwiftUI

/// Menu-bar (标题栏) monitor menu: daemon status + quick actions.
struct MonitorMenuView: View {
    @EnvironmentObject private var monitor: MonitorModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.connected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(monitor.connected ? "GVGL 已连接" : "GVGL 未连接")
                    .font(.headline)
                Spacer()
                if let status = monitor.status {
                    Text("v\(status.version)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let error = monitor.errorMessage, !monitor.connected {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            if let status = monitor.status {
                Divider()
                LabeledContent("监控 App") { Text("\(status.monitoredApps)") }
                LabeledContent("帧状态") { Text(status.frameStatus) }
                LabeledContent("AX 权限") {
                    Text(status.permissionGranted ? "已授予" : "未授予")
                        .foregroundStyle(status.permissionGranted ? .green : .red)
                }
                LabeledContent("socket") {
                    Text(status.socket)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                }
            }

            Divider()

            Button {
                openWindow(id: "console")
            } label: {
                Label("打开审查台", systemImage: "macwindow")
            }
            Button {
                monitor.launchDaemon()
            } label: {
                Label(monitor.connected ? "重启守护进程" : "启动守护进程",
                      systemImage: monitor.connected ? "arrow.counterclockwise.circle" : "play.circle")
            }
            Button {
                monitor.autoWatch.toggle()
                monitor.refreshNow()
            } label: {
                Label(monitor.autoWatch ? "暂停监控" : "恢复监控",
                      systemImage: monitor.autoWatch ? "pause.circle" : "play.circle.fill")
            }
            Button {
                monitor.refreshNow()
            } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }

            Divider()

            Button("退出 GVGL") { monitor.quit() }
        }
        .padding(8)
        .frame(minWidth: 260)
    }
}
