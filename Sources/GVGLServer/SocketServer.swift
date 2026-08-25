import ApplicationServices
import Darwin
import Foundation
import GVGLCore
import GVGLSync

/// Unix Domain Socket server. Protocol: NDJSON — one JSON request line, one
/// JSON response line per connection.
///
/// Methods:
///   {"method":"get_frame"}                          → {"result": GVGLFrame}
///   {"method":"get_frame","app":"pid:123"}          → frame filtered to one app
///   {"method":"get_status"}                         → daemon status
public final class SocketServer: @unchecked Sendable {
    public enum ServerError: Error, CustomStringConvertible {
        case socketFailed(String)
        case bindFailed(String)
        case listenFailed(String)

        public var description: String {
            switch self {
            case .socketFailed(let m): return "socket() failed: \(m)"
            case .bindFailed(let m): return "bind() failed: \(m)"
            case .listenFailed(let m): return "listen() failed: \(m)"
            }
        }
    }

    private let socketPath: String
    public let model: DesktopModel
    private let engine: SyncEngine
    private let verbose: Bool
    private let queue = DispatchQueue(label: "gvgl.server", attributes: .concurrent)
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    public init(socketPath: String, model: DesktopModel, engine: SyncEngine, verbose: Bool = false) {
        self.socketPath = socketPath
        self.model = model
        self.engine = engine
        self.verbose = verbose
    }

    public func start() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed(String(cString: strerror(errno))) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: Int8.self, capacity: 108) { dst in
                strlcpy(dst, socketPath, 108)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.bindFailed(String(cString: strerror(errno)))
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw ServerError.listenFailed(String(cString: strerror(errno)))
        }

        lock.lock()
        listenFD = fd
        running = true
        lock.unlock()
        acceptLoop()
    }

    public func stop() {
        lock.lock()
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        lock.unlock()
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        queue.async { [weak self] in
            while let self {
                self.lock.lock()
                let fd = self.listenFD
                let shouldRun = self.running
                self.lock.unlock()
                guard shouldRun, fd >= 0 else { return }

                let client = accept(fd, nil, nil)
                guard client >= 0 else {
                    let err = errno
                    // ECONNABORTED is benign (client raced the accept).
                    if err != EINTR, err != ECONNABORTED {
                        fputs("gvgl: accept error errno=\(err) (\(String(cString: strerror(err))))\n", stderr)
                    }
                    continue
                }
                queue.async { [self] in self.handleConnection(client) }
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 65536)
        var data = Data()
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.contains(0x0A) { break }
        }

        let requestLine = String(data: data, encoding: .utf8) ?? ""
        let started = Date()
        let (response, subscription) = route(requestLine.trimmingCharacters(in: .whitespacesAndNewlines))
        // NDJSON: every response line must end with a newline.
        if let payload = (response + "\n").data(using: .utf8) {
            let bytes = payload
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
        }
        if let subscription {
            pushLoop(fd, from: subscription.lastVersion, mask: subscription.mask)
        }
        if verbose {
            fputs("gvgl: served \(requestLine.prefix(60)) -> \(response.count) bytes in \(Int(Date().timeIntervalSince(started) * 1000))ms\n", stderr)
        }
    }

    // MARK: - Push subscription

    /// Long-lived push loop: writes one NDJSON event line per model version
    /// bump. With a region mask (V5.1), only bumps touching one of the masked
    /// buckets are pushed — an agent watching "display 1's q2" doesn't hear
    /// about every other region's churn. Ends when the client goes away
    /// (EPIPE) or the loop is interrupted.
    private func pushLoop(_ fd: Int32, from initial: UInt64, mask: Set<String>?) {
        var last = initial
        var quietTimeouts = 0
        while true {
            guard let newVersion = model.waitForVersion(after: last, timeout: 5) else {
                // No change within the window. Ping occasionally so a dead
                // client on a quiet desktop is detected and reaped.
                quietTimeouts += 1
                if quietTimeouts % 12 == 0 {
                    let ping = "{\"event\":\"ping\",\"version\":\(model.version)}\n"
                    guard Self.writeLine(fd, ping) else { return }
                }
                continue
            }
            quietTimeouts = 0
            let apps = model.changedApps(after: last)
            let regions = model.changedRegions(after: last)
            last = newVersion
            if let mask, mask.isDisjoint(with: regions) {
                continue // masked out: advance the cursor, stay silent
            }
            let event = PushEvent(event: "frame", version: newVersion, changed_apps: apps, changed_regions: regions)
            guard let payload = try? JSONEncoder.gvgl.encode(event),
                  let line = String(data: payload, encoding: .utf8) else { return }
            guard Self.writeLine(fd, line + "\n") else { return }
        }
    }

    private static func writeLine(_ fd: Int32, _ line: String) -> Bool {
        guard let payload = line.data(using: .utf8) else { return false }
        let bytes = payload
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
        return n == bytes.count
    }

    // MARK: - Routing

    private struct Request: Decodable {
        var method: String
        var app: String?
        var since: UInt64?
        /// V4: scene-tree depth limit (levels below each app root).
        var depth: Int?
        /// V5.1: region-bucket mask ("d<displayID>q<region>", e.g. "d1q2";
        /// "sys" for frontmost changes). Only version bumps touching one of
        /// these buckets are pushed.
        var regions: [String]?
    }

    private struct Subscription {
        var lastVersion: UInt64
        var mask: Set<String>?
    }

    private struct ChangedResult: Codable {
        var event: String
        var version: UInt64
        var changed_apps: [String]
        var frame: GVGLFrame
    }

    private struct SubscribedResult: Codable {
        var event: String
        var version: UInt64
    }

    private struct PushEvent: Codable {
        var event: String
        var version: UInt64
        var changed_apps: [String]
        /// V5.1: region buckets touched by this change ("d<displayID>q<region>",
        /// "sys" for frontmost); empty for structural-only bumps.
        var changed_regions: [String]
    }

    private func route(_ line: String) -> (String, Subscription?) {
        guard !line.isEmpty else {
            return (Self.errorResponse("invalid_request", "empty request"), nil)
        }
        let request: Request
        do {
            request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
        } catch {
            return (Self.errorResponse("invalid_request", "malformed JSON: \(error)"), nil)
        }

        switch request.method {
        case "get_frame":
            guard AXIsProcessTrusted() else {
                return (Self.errorResponse("permission_denied", "Accessibility permission not granted"), nil)
            }
            let depth = request.depth.flatMap { $0 > 0 ? $0 : nil }
            if let since = request.since {
                // Incremental pull: report only what changed since `since`.
                let result = model.frameResult(screen: engine.screen, filterApp: request.app, since: since, depth: depth)
                if result.frame.version <= since {
                    let text = """
                    {"result":{"event":"no_change","version":\(since)}}
                    """
                    return (text, nil)
                }
                let changed = ChangedResult(
                    event: "changed",
                    version: result.frame.version,
                    changed_apps: result.changedApps,
                    frame: result.frame
                )
                guard let payload = try? JSONEncoder.gvgl.encode(["result": changed]),
                      let text = String(data: payload, encoding: .utf8) else {
                    return (Self.errorResponse("internal", "frame serialization failed"), nil)
                }
                return (text, nil)
            }
            let frame = model.frame(screen: engine.screen, filterApp: request.app, depth: depth)
            guard let payload = try? JSONEncoder.gvgl.encode(["result": frame]),
                  let text = String(data: payload, encoding: .utf8) else {
                return (Self.errorResponse("internal", "frame serialization failed"), nil)
            }
            return (text, nil)

        case "subscribe":
            let initial = request.since ?? model.version
            let subscribed = SubscribedResult(event: "subscribed", version: model.version)
            guard let payload = try? JSONEncoder.gvgl.encode(["result": subscribed]),
                  let text = String(data: payload, encoding: .utf8) else {
                return (Self.errorResponse("internal", "serialization failed"), nil)
            }
            return (text, Subscription(lastVersion: initial, mask: request.regions.map(Set.init)))

        case "get_map":
            guard AXIsProcessTrusted() else {
                return (Self.errorResponse("permission_denied", "Accessibility permission not granted"), nil)
            }
            // Coarse agent minimap (V5): displays + top-level windows in
            // Display Space with quadrant labels. Derived from the cached
            // frame — millisecond-scale, no AX calls.
            let map = model.frame(screen: engine.screen).desktopMap
            guard let payload = try? JSONEncoder.gvgl.encode(["result": map]),
                  let text = String(data: payload, encoding: .utf8) else {
                return (Self.errorResponse("internal", "map serialization failed"), nil)
            }
            return (text, nil)

        case "get_status":
            let s = engine.status()
            let statusPayload = StatusPayload(
                monitoredApps: s.monitoredApps,
                version: s.version,
                permissionGranted: s.permissionGranted,
                uptime: Date().timeIntervalSince(startTime),
                socket: socketPath,
                frameStatus: model.frame(screen: engine.screen).status.rawValue
            )
            guard let payload = try? JSONEncoder.gvgl.encode(["result": statusPayload]),
                  let text = String(data: payload, encoding: .utf8) else {
                return (Self.errorResponse("internal", "status serialization failed"), nil)
            }
            return (text, nil)

        default:
            return (Self.errorResponse("invalid_method", "unknown method '\(request.method)'"), nil)
        }
    }

    private static func errorResponse(_ code: String, _ message: String) -> String {
        let body = """
        {"error":{"code":"\(code)","message":"\(message)"}}
        """
        return body
    }

    private struct StatusPayload: Codable {
        var monitoredApps: Int
        var version: UInt64
        var permissionGranted: Bool
        var uptime: TimeInterval
        var socket: String
        var frameStatus: String
    }

    private let startTime = Date()
}
