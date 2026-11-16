import Darwin
import Foundation
import GVGLCore
import GVGLAction
import GVGLQuery

/// gvglact — the computer-use execution half of GVGL.
///
/// Reads the geometric model through the daemon, acts through the
/// Accessibility API and synthetic HID events, then verifies the reaction.
/// One JSON line per invocation; exit 0 when the action succeeded.

// MARK: - Arguments

struct ParsedArgs {
    private var options: [String: [String]] = [:]
    private var flags: Set<String> = []
    private var positionals: [String] = []

    static let booleanFlags: Set<String> = [
        "dry-run", "no-verify", "pretty", "allow-ambiguous",
        "allow-secure-field", "allow-blind-click", "help", "submit",
    ]

    static func parse(_ tokens: [String]) -> ParsedArgs {
        var parsed = ParsedArgs()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--") {
                var name = String(token.dropFirst(2))
                var inlineValue: String?
                if let equals = name.firstIndex(of: "=") {
                    inlineValue = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                if let inlineValue {
                    parsed.options[name, default: []].append(inlineValue)
                } else if booleanFlags.contains(name) {
                    parsed.flags.insert(name)
                } else if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") {
                    parsed.options[name, default: []].append(tokens[index + 1])
                    index += 1
                } else {
                    parsed.flags.insert(name)
                }
            } else {
                parsed.positionals.append(token)
            }
            index += 1
        }
        return parsed
    }

    func value(_ name: String) -> String? { options[name]?.last }
    func all(_ name: String) -> [String] { options[name] ?? [] }
    func has(_ name: String) -> Bool { flags.contains(name) }
    func int(_ name: String) -> Int? { value(name).flatMap(Int.init) }
    var positional: [String] { positionals }
}

struct UsageError: Error { var message: String }

// MARK: - Output

func emit(_ result: ActionResult, pretty: Bool) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty
        ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        : [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(result))
        ?? Data(#"{"ok":false,"error":{"code":"internal_error","message":"encode failed"}}"#.utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(result.ok ? 0 : 1)
}

func emitUsage(_ message: String? = nil) -> Never {
    if let message {
        FileHandle.standardError.write(Data("gvglact: \(message)\n".utf8))
    }
    FileHandle.standardError.write(Data(usageText.utf8))
    exit(2)
}

let usageText = """
gvglact — act on the desktop through Accessibility, without screenshots

usage: gvglact <command> [target] [flags]

commands:
  status                          AX trust + daemon status
  find                            locate elements (no action)
  press    --id ID | --role R --label L      semantic AXPress (click fallback)
  click    <target>               pointer click (hit-tested; --button, --count)
  type     <target> --text TEXT   set value / paste / unicode keys; --submit
  key      --chord "cmd+s"        keyboard chord; optional --app or --id
  scroll   <target>               --up N | --down N | --to top|bottom
  drag     --from ID --to ID      pointer drag between two elements
  menu     --app pid:N --path "A/B"   drive the menu bar by path or indices
  text     <target>               read the full AXValue (--max N)
  transcript [--app pid:N] [--window ID]
                                  read a window/desktop as text, in AX order
  focus    <target>               move keyboard focus
  set      <target> --value TEXT  write AXValue atomically
  app      activate|launch|list [target]
  clipboard get|set [--text TEXT]
  wait     --since VERSION        block until the model changes

target flags:
  --id pid:NNN:0-2-3     exact element id from a frame
  --role AXButton        role filter
  --label 登录           title / placeholder / value / identifier match
  --app pid:NNN          restrict to one app
  --display N            physical display id
  --region q1..q4        quadrant (display space)
  --reference ID --relation right-of   spatial filter
  --top N                candidates to score (default 5)

global flags:
  --socket PATH          default ~/.gvgl/gvgl.sock or $GVGL_SOCKET
  --dry-run              resolve + hit-test, then stop
  --no-verify            do not wait for / report the reaction
  --timeout SECONDS      verification window (default 2)
  --allow-app KEY[,KEY]  restrict actions to these apps (pid:NNN, pid, or name)
  --allow-ambiguous      act when candidates are nearly tied
  --allow-secure-field   permit typing into AXSecureTextField
  --allow-blind-click    permit clicking when hit-testing is unavailable
  --pretty               indented JSON
"""

// MARK: - Helpers

func target(_ args: ParsedArgs) throws -> TargetSpec {
    if let id = args.value("id") {
        return .id(id)
    }
    var params = QueryParams()
    params.role = args.value("role")
    params.label = args.value("label")
    params.region = args.value("region")?.lowercased()
    params.app = args.value("app")
    params.display = args.int("display")
    params.refID = args.value("reference")
    params.refDir = args.value("relation")
    params.top = args.int("top") ?? 5
    guard params.role != nil || params.label != nil || params.region != nil
            || params.refID != nil else {
        throw UsageError(message: "target required: --id, or --role / --label / --region / --reference")
    }
    return .query(params)
}

func queryParams(_ args: ParsedArgs) -> QueryParams {
    var params = QueryParams()
    params.role = args.value("role")
    params.label = args.value("label")
    params.region = args.value("region")?.lowercased()
    params.app = args.value("app")
    params.display = args.int("display")
    params.refID = args.value("reference")
    params.refDir = args.value("relation")
    params.top = args.int("top") ?? 10
    return params
}

func targetJSON(_ scored: ScoredEntity, frame: GVGLFrame) -> JSONValue {
    let entity = scored.entity
    let pixel = QueryEngine.pixelCenter(of: entity, screen: frame.screen)
    return .object([
        "id": .string(entity.id),
        "role": .string(entity.role),
        "title": entity.title.map(JSONValue.string) ?? .null,
        "detail": entity.detail.map(JSONValue.string) ?? .null,
        "value": entity.value.map(JSONValue.string) ?? .null,
        "placeholder": entity.placeholder.map(JSONValue.string) ?? .null,
        "app": .string(entity.appID),
        "app_name": entity.appName.map(JSONValue.string) ?? .null,
        "window": entity.windowID.map(JSONValue.string) ?? .null,
        "display": entity.displayID.map { .number(Double($0)) } ?? .null,
        "region": .string(entity.geometry.region.rawValue),
        "focused": .bool(entity.focused),
        "enabled": .bool(entity.enabled),
        "actions": .array(entity.actions.map(JSONValue.string)),
        "score": .number(scored.score),
        "pixel": .numbers([pixel.x, pixel.y]),
    ])
}

func exitWithFailure(_ command: String, _ error: ActionError, pretty: Bool) -> Never {
    emit(ActionResult.failure(command, error), pretty: pretty)
}

// MARK: - Main

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { emitUsage() }
if command == "--help" || command == "-h" || command == "help" { emitUsage() }

let args = ParsedArgs.parse(Array(argv.dropFirst()))
let pretty = args.has("pretty")

let socketPath = args.value("socket")
    ?? ProcessInfo.processInfo.environment["GVGL_SOCKET"]
    ?? GVGLClient.defaultSocketPath

var options = ExecutorOptions(socketPath: socketPath)
options.dryRun = args.has("dry-run")
options.verify = !args.has("no-verify")
options.allowAmbiguous = args.has("allow-ambiguous")
options.allowSecureFields = args.has("allow-secure-field")
options.allowBlindClick = args.has("allow-blind-click")
if let timeout = args.value("timeout").flatMap(Double.init) {
    options.timeout = timeout
}
let allowApps = args.all("allow-app").flatMap { $0.split(separator: ",").map(String.init) }
if !allowApps.isEmpty {
    options.allowAppKeys = Set(allowApps)
}

let executor = ActionExecutor(options: options)

do {
    let result: ActionResult
    switch command {
    case "status":
        result = try executor.status()

    case "find":
        let params = queryParams(args)
        let (results, frame) = try executor.find(params)
        var found = ActionResult(action: "find")
        found.data = .array(results.map { targetJSON($0, frame: frame) })
        found.method = "query_engine"
        if let best = results.first {
            found.target = ActionTargetSummary(entity: best.entity)
            if best.score < 0.7 {
                found.warnings.append("low confidence: best score \(String(format: "%.2f", best.score))")
            }
        } else {
            found.warnings.append("no candidates")
        }
        result = found

    case "press":
        result = try executor.press(try target(args), axAction: args.value("ax-action"))

    case "click":
        let button = InputSynthesizer.MouseButton(rawValue: args.value("button") ?? "left") ?? .left
        let count = args.int("count") ?? 1
        result = try executor.click(try target(args), button: button, count: count)

    case "type":
        guard let text = args.value("text") else {
            throw UsageError(message: "type requires --text")
        }
        let method = TypeMethod(rawValue: args.value("method") ?? "auto") ?? .auto
        result = try executor.type(try target(args), text: text,
                                   method: method, submit: args.has("submit"))

    case "key":
        guard let chord = args.value("chord") else {
            throw UsageError(message: "key requires --chord (e.g. \"cmd+s\")")
        }
        let explicit: TargetSpec? = args.value("id") != nil ? try target(args) : nil
        result = try executor.sendKey(chord, target: explicit, app: args.value("app"))

    case "scroll":
        let lines: Int32
        if let up = args.int("up") {
            lines = Int32(up)
        } else if let down = args.int("down") {
            lines = Int32(-down)
        } else {
            lines = 3
        }
        result = try executor.scroll(try target(args), lines: lines, to: args.value("to"))

    case "drag":
        guard let fromValue = args.value("from"), let toValue = args.value("to") else {
            throw UsageError(message: "drag requires --from and --to (element ids or labels)")
        }
        let fromSpec: TargetSpec = ElementPath.parse(fromValue) != nil
            ? .id(fromValue)
            : .query(QueryParams(role: args.value("from-role"), label: fromValue))
        let toSpec: TargetSpec = ElementPath.parse(toValue) != nil
            ? .id(toValue)
            : .query(QueryParams(role: args.value("to-role"), label: toValue))
        result = try executor.drag(from: fromSpec, to: toSpec)

    case "transcript":
        result = try executor.transcript(
            appKey: args.value("app"),
            windowID: args.value("window"),
            maxChars: args.int("max") ?? 20000
        )

    case "menu":
        guard let app = args.value("app") else {
            throw UsageError(message: "menu requires --app pid:NNN")
        }
        var path = args.all("step")
        if path.isEmpty, let joined = args.value("path") {
            path = joined.split(whereSeparator: { $0 == "/" || $0 == ">" || $0 == "|" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        guard !path.isEmpty else {
            throw UsageError(message: "menu requires --path \"File/New\" or --step segments")
        }
        result = try executor.menu(appKey: app, path: path)

    case "text":
        result = try executor.readText(try target(args), cap: args.int("max") ?? 8000)

    case "focus":
        result = try executor.focus(try target(args))

    case "set":
        guard let value = args.value("value") else {
            throw UsageError(message: "set requires --value")
        }
        result = try executor.setValue(try target(args), text: value)

    case "app":
        guard let verb = args.positional.first else {
            throw UsageError(message: "app requires activate|launch|list")
        }
        let appTarget = args.positional.dropFirst().first ?? args.value("target")
        result = try executor.appAction(verb, target: appTarget)

    case "clipboard":
        guard let verb = args.positional.first else {
            throw UsageError(message: "clipboard requires get|set")
        }
        result = try executor.clipboardAction(verb, text: args.value("text"))

    case "wait":
        let since = args.value("since").flatMap(UInt64.init)
        let timeout = args.value("timeout").flatMap(Double.init) ?? 5.0
        result = try executor.waitForChange(since: since, timeout: timeout)

    default:
        throw UsageError(message: "unknown command '\(command)'")
    }
    emit(result, pretty: pretty)
} catch let failure as ActionFailure {
    exitWithFailure(command, failure.error, pretty: pretty)
} catch let usage as UsageError {
    emitUsage(usage.message)
} catch {
    exitWithFailure(command, ActionError(.internalError, "\(error)"), pretty: pretty)
}
