import SwiftUI

/// Screenshot-free observation panel: the selected window (or the frontmost
/// app) rendered as text in accessibility-tree order.
///
/// This is the console's answer to "show me what's on screen" without capturing
/// pixels: headings, static text, controls and menu items come from the AX
/// tree, so the panel is searchable, selectable and cheap to refresh.
struct TranscriptView: View {
    @ObservedObject var model: DesktopViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("窗口文本 · AX（无截图）")
                    .font(.caption.weight(.semibold))
                if let label = model.transcriptLabel {
                    Text("· \(label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("选中窗口") { model.loadTranscriptForSelection() }
                    .disabled(model.selectedEntity == nil)
                Button("前台 App") { model.loadTranscriptFrontmost() }
                if model.busy { ProgressView().controlSize(.small) }
            }
            .controlSize(.mini)
            .buttonStyle(.bordered)

            ScrollView {
                Text(model.transcript ?? "读取选中窗口或前台 App，这里会显示 AX 树的文本内容（无需截图）。")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
