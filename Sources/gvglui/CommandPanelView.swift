import SwiftUI
import GVGLCore
import GVGLQuery

/// Bottom panel: instruction input + parsed result + scored candidates with
/// locate / execute actions (人工指令模拟 AI 指令测试).
struct CommandPanelView: View {
    @ObservedObject var model: DesktopViewModel
    @State private var instruction: String = "点击 登录 按钮"
    @State private var parseError: String?

    private let examples = [
        "点击 登录 按钮",
        "点击右上角的搜索框",
        "在 搜索框 右侧的 关闭 按钮",
        "query --role AXButton --label 登录 --top 3",
        "点击 --reference pid:1:0-1 --relation right-of",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                TextField("输入指令，如：点击 登录 按钮", text: $instruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                Button("运行", action: run)
                    .keyboardShortcut(.defaultAction)
                Menu("示例") {
                    ForEach(examples, id: \.self) { ex in
                        Button(ex) { instruction = ex }
                    }
                }
            }

            if let error = parseError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if let parsed = model.lastParsed {
                HStack(spacing: 10) {
                    Text("动作: \(parsed.action.rawValue)")
                    if let role = parsed.params.role { Text("角色: \(role)") }
                    if let label = parsed.params.label { Text("标题: 「\(label)」") }
                    if let region = parsed.params.region { Text("区域: \(region)") }
                    if let dir = parsed.params.refDir { Text("关系: \(dir)") }
                    if let ref = parsed.reference { Text("参照: 「\(ref.label ?? "")」") }
                    Spacer()
                    if let result = model.lastResult {
                        Text("置信度: \(result.status.rawValue)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor(result.status))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let result = model.lastResult {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(result.ranked.enumerated()), id: \.element.id) { index, scored in
                            resultCard(index: index, scored: scored, result: result)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if result.status == .axWeak, !result.weakElements.isEmpty {
                    Text("弱 AX：\(result.weakElements.count) 个元素无可用标题，已返回结构化摘要，请人工/上层决策")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("运行一条指令后在此显示评分结果（§6.2 五维评分）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func run() {
        parseError = nil
        do {
            try model.runInstruction(instruction)
        } catch {
            parseError = error.localizedDescription
        }
    }

    private func statusColor(_ status: QueryStatus) -> Color {
        switch status {
        case .hit: return .green
        case .ambiguous: return .orange
        case .axWeak: return .orange
        case .notFound: return .red
        }
    }

    private func resultCard(index: Int, scored: ScoredEntity, result: QueryResult) -> some View {
        let e = scored.entity
        let isBest = result.best?.id == scored.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(index + 1)")
                    .font(.caption2.weight(.bold))
                if isBest { Text("BEST").font(.caption2.weight(.bold)).foregroundStyle(.green) }
                Spacer()
                Text(String(format: "%.2f", scored.score))
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            Text(entityDisplayTitle(e))
                .font(.callout).lineLimit(1)
            Text("\(e.role) · \(e.id)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 8) {
                Text("语义 \(fmt(scored.breakdown["semantic"]))")
                Text("角色 \(fmt(scored.breakdown["role"]))")
                Text("空间 \(fmt(scored.breakdown["spatial"]))")
                Text("尺寸 \(fmt(scored.breakdown["size"]))")
                Text("拓扑 \(fmt(scored.breakdown["topology"]))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("定位") { model.select(e.id) }
                Button("点击") {
                    guard model.allowExecute else {
                        parseError = "请在侧栏开启「允许执行点击」"
                        return
                    }
                    model.executeClick(e)
                }
                .disabled(!model.allowExecute)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(8)
        .frame(width: 230, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isBest ? Color.accentColor.opacity(0.12) : Color.black.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isBest ? Color.accentColor : Color.clear, lineWidth: 1)
        )
    }

    private func fmt(_ value: Double?) -> String {
        String(format: "%.1f", value ?? 0)
    }
}
