import AppKit
import Darwin
import Foundation
import GVGLCore
import GVGLSync
import GVGLServer

private func mainScreenInfo() -> ScreenInfo {
    let main = CGMainDisplayID()
    let mainBounds = CGDisplayBounds(main)
    let mainWidth = Double(CGDisplayPixelsWide(main))
    let mainHeight = Double(CGDisplayPixelsHigh(main))

    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
    var displays: [DisplayInfo] = []
    for i in 0..<Int(count) {
        let id = ids[i]
        let bounds = CGDisplayBounds(id)
        let width = Double(CGDisplayPixelsWide(id))
        displays.append(DisplayInfo(
            id: Int(id),
            x: bounds.minX, y: bounds.minY,
            width: bounds.width, height: bounds.height,
            scaleFactor: width / max(bounds.width, 1)
        ))
    }
    // Main display first, rest ordered by x.
    displays.sort { a, b in
        if a.id == Int(main) { return true }
        if b.id == Int(main) { return false }
        return a.x < b.x
    }

    return ScreenInfo(
        width: mainWidth, height: mainHeight,
        scaleFactor: mainWidth / max(mainBounds.width, 1),
        displays: displays
    )
}

private var socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".gvgl/gvgl.sock").path
private var reconcileInterval: Double = 3.0
private var onlyApps: String?
private var indexGrid: Int = 0
private var cgCheck = false
private var verbose = false
private var server: SocketServer?
private var engine: SyncEngine?

private func parseArguments() {
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--socket":
            i += 1
            if i < args.count { socketPath = args[i] }
        case "--reconcile":
            i += 1
            if i < args.count { reconcileInterval = Double(args[i]) ?? 3.0 }
        case "--only-apps":
            i += 1
            if i < args.count { onlyApps = args[i] }
        case "--index-grid":
            i += 1
            if i < args.count { indexGrid = max(0, Int(args[i]) ?? 0) }
        case "--cg-check":
            cgCheck = true
        case "--verbose":
            verbose = true
        case "--version":
            print("gvgl 0.1.0")
            exit(0)
        case "--print-socket":
            print(socketPath)
            exit(0)
        case "--help", "-h":
            print("""
            gvgl — semi-sync virtual desktop daemon
            usage: gvgl [--socket PATH] [--reconcile SECONDS] [--only-apps com.a,com.b]
                        [--index-grid N] [--cg-check] [--verbose] [--version] [--print-socket]
            """)
            exit(0)
        default:
            break
        }
        i += 1
    }
}

private func installSignalHandlers() {
    func handler() {
        server?.stop()
        engine?.stop()
        unlink(socketPath)
        exit(0)
    }
    // A client that disconnects mid-push would otherwise kill the daemon with
    // SIGPIPE; writes then return EPIPE and the push loop exits cleanly.
    signal(SIGPIPE, SIG_IGN)
    // DispatchSourceSignal installs its own handlers; do NOT also call
    // signal(SIGTERM, SIG_IGN) — that would override the source and swallow
    // the signal (observed: daemon became SIGTERM-unkillable).
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { handler() }
    sigint.resume()
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigterm.setEventHandler { handler() }
    sigterm.resume()
}

parseArguments()
installSignalHandlers()
setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

let model = DesktopModel()
let capturer = Snapshotter(config: SnapshotConfig(cgProbeEnabled: cgCheck))
let engineInstance = SyncEngine(
    model: model,
    capturer: capturer,
    screen: mainScreenInfo(),
    reconciliationInterval: reconcileInterval
)
if let onlyApps {
    engineInstance.allowedBundleIDs = Set(onlyApps.split(separator: ",").map(String.init))
}
engineInstance.screenReader = mainScreenInfo
engineInstance.indexGridSize = indexGrid
model.gridSize = indexGrid
engine = engineInstance

let serverInstance = SocketServer(socketPath: socketPath, model: model, engine: engineInstance, verbose: verbose)
server = serverInstance
try serverInstance.start()
engineInstance.start()

// Original doc §6.1: 权限检测 + 引导弹窗（必须）
if !AXIsProcessTrusted() {
    FileHandle.standardError.write(Data("""
    warning: Accessibility permission not granted.
    Frames will report permission_denied until granted.
    """.utf8))
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
        FileHandle.standardError.write(Data("""
    Opened System Settings > Privacy & Security > Accessibility.
    Enable accessibility for the launching app (terminal, or the gvgl binary itself
    when run via launchd), then restart gvgl.
    """.utf8))
    }
}

print("gvgl 0.1.0 listening on \(socketPath) — virtual desktop live")
RunLoop.main.run()
