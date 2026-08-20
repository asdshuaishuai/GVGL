import Foundation
import GVGLCore

public enum InstructionAction: String, Hashable {
    case click
    case doubleClick
    case query
    case inspect
}

/// Reference spec for two-stage relation queries ("在 <refLabel> 右侧的 <target>").
public struct InstructionReference: Hashable {
    public let label: String?
    public let role: String?

    public init(label: String?, role: String?) {
        self.label = label
        self.role = role
    }
}

/// Parsed natural-language / CLI instruction (人工指令 → 结构化查询).
public struct ParsedInstruction: Hashable {
    public let action: InstructionAction
    public let params: QueryParams
    /// Two-stage relation query: "在 <refLabel> 右侧的 <target>".
    public let reference: InstructionReference?

    public init(action: InstructionAction, params: QueryParams, reference: InstructionReference? = nil) {
        self.action = action
        self.params = params
        self.reference = reference
    }
}

public enum ParseError: Error, LocalizedError, Equatable {
    case empty
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "指令为空"
        case .malformed(let m): return "无法解析指令: \(m)"
        }
    }
}

/// Parses instructions like:
///   "点击 登录 按钮" / "点击右上角的登录按钮"
///   "在 搜索框 右侧的 关闭 按钮"  (two-stage relation)
///   "query --role AXButton --label 登录 --region q2"  (CLI passthrough)
public enum InstructionParser {
    public static let roleWords: [(word: String, role: String)] = [
        // Longer/specific first so "输入框" wins over "输入".
        ("输入框", "AXTextField"), ("文本框", "AXTextField"), ("搜索框", "AXTextField"),
        ("复选框", "AXCheckBox"), ("勾选框", "AXCheckBox"),
        ("单选框", "AXRadioButton"), ("菜单项", "AXMenuItem"),
        ("组合框", "AXComboBox"),
        ("按钮", "AXButton"), ("按键", "AXButton"),
        ("窗口", "AXWindow"), ("图片", "AXImage"), ("图像", "AXImage"),
        ("文本", "AXStaticText"), ("标签", "AXStaticText"),
        ("菜单", "AXMenuItem"), ("链接", "AXLink"),
        ("滑块", "AXSlider"), ("下拉", "AXComboBox"),
        ("输入", "AXTextField"), ("单选", "AXRadioButton"),
    ]

    public static let regionWords: [String: String] = [
        "左上角": "q1", "右上角": "q2", "左下角": "q3", "右下角": "q4",
    ]

    public static let relationWords: [String: String] = [
        "右侧": "rightOf", "右边": "rightOf",
        "左侧": "leftOf", "左边": "leftOf",
        "上方": "above", "上面": "above",
        "下方": "below", "下面": "below",
        "附近": "near", "旁边": "near",
    ]

    public static let verbWords: Set<String> = ["点击", "单击", "双击", "按下", "执行", "查找", "查询", "查看", "定位", "检查"]

    public static func parse(_ input: String) throws -> ParsedInstruction {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        if trimmed.contains("--") {
            return try parseCLI(trimmed)
        }
        return try parseChinese(trimmed)
    }

    // MARK: - CLI passthrough ("query --role AXButton --label 登录 --region q2")

    private static func parseCLI(_ input: String) throws -> ParsedInstruction {
        let tokens = input.split(separator: " ").map(String.init)
        var params = QueryParams()
        var action: InstructionAction = .query
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            switch t {
            case "点击", "单击": action = .click
            case "双击": action = .doubleClick
            case "query", "查询", "search": break
            case "--role":
                i += 1
                if i < tokens.count { params.role = tokens[i] }
            case "--label":
                i += 1
                if i < tokens.count { params.label = tokens[i] }
            case "--region":
                i += 1
                if i < tokens.count { params.region = tokens[i].lowercased() }
            case "--app":
                i += 1
                if i < tokens.count { params.app = tokens[i] }
            case "--reference":
                i += 1
                if i < tokens.count { params.refID = tokens[i] }
            case "--relation":
                i += 1
                if i < tokens.count {
                    params.refDir = tokens[i]
                        .replacingOccurrences(of: "left-of", with: "leftOf")
                        .replacingOccurrences(of: "right-of", with: "rightOf")
                }
            case "--top":
                i += 1
                if i < tokens.count { params.top = Int(tokens[i]) ?? 5 }
            default:
                // Bare tokens before flags → label.
                if params.label == nil {
                    params.label = t
                }
            }
            i += 1
        }
        return ParsedInstruction(action: action, params: params)
    }

    // MARK: - Chinese natural language

    private static func parseChinese(_ input: String) throws -> ParsedInstruction {
        var text = input
        // Expand compound words into standalone tokens ("登录按钮" → "登录 按钮",
        // "点击右上角" → "点击 右上角").
        for (word, _) in roleWords {
            text = text.replacingOccurrences(of: word, with: " \(word) ")
        }
        for (word, _) in regionWords {
            text = text.replacingOccurrences(of: word, with: " \(word) ")
        }
        for particle in ["的", "在", "中", "里面"] {
            text = text.replacingOccurrences(of: particle, with: " ")
        }
        var tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        tokens = tokens.filter { !$0.isEmpty }

        var action: InstructionAction = .query
        var params = QueryParams()
        var refLabelTokens: [String] = []
        var refRole: String?
        var targetLabelTokens: [String] = []

        // Phase tracking: tokens before the relation word belong to the
        // reference spec; tokens after it to the target spec. Token inserts
        // (verb stripping) are safe because the phase flips on encounter
        // rather than by precomputed index.
        var inReference = true
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            i += 1

            if let rel = relationWords[token] {
                params.refDir = rel
                inReference = false
                continue
            }
            if let verb = verbWords.first(where: { token.hasPrefix($0) }) {
                apply(verb: verb, action: &action)
                let rest = String(token.dropFirst(verb.count))
                if !rest.isEmpty {
                    tokens.insert(rest, at: i)
                }
                continue
            }
            if let region = regionWords[token] {
                params.region = region
                continue
            }
            if let role = roleForToken(token) {
                if inReference {
                    refRole = role
                    refLabelTokens.append(token)
                } else {
                    params.role = role
                }
                continue
            }
            if inReference {
                refLabelTokens.append(token)
            } else {
                targetLabelTokens.append(token)
            }
        }

        if inReference {
            // No relation word: everything collected is the target spec.
            // Role words are extracted as the role — filter them out of the
            // label ("点击 登录 按钮" → label 登录, role AXButton).
            let labelTokens = refLabelTokens.filter { roleForToken($0) == nil }
            params.label = labelTokens.isEmpty ? nil : labelTokens.joined(separator: " ")
            if params.role == nil { params.role = refRole }
            return ParsedInstruction(action: action, params: params)
        }
        let refLabel = refLabelTokens.isEmpty ? nil : refLabelTokens.joined(separator: " ")
        params.label = targetLabelTokens.isEmpty ? nil : targetLabelTokens.joined(separator: " ")
        return ParsedInstruction(action: action, params: params,
                                 reference: InstructionReference(label: refLabel, role: refRole))
    }

    private static func apply(verb: String, action: inout InstructionAction) {
        switch verb {
        case "点击", "单击", "按下", "执行": action = .click
        case "双击": action = .doubleClick
        default: break
        }
    }

    private static func roleForToken(_ token: String) -> String? {
        for (word, role) in roleWords where token == word {
            return role
        }
        return nil
    }
}
