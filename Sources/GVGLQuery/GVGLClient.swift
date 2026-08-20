import Darwin
import Foundation
import GVGLCore

/// UDS NDJSON client for the GVGL daemon (mirrors client/gvgl_query.py).
/// Methods are synchronous with a receive timeout; call them off the main
/// thread.
public final class GVGLClient: @unchecked Sendable {
    public enum ClientError: Error, LocalizedError {
        case connectionFailed(String)
        case daemonError(code: String, message: String)
        case malformedResponse(String)

        public var errorDescription: String? {
            switch self {
            case .connectionFailed(let m): return "无法连接守护进程: \(m)"
            case .daemonError(let code, let message): return "守护进程错误 [\(code)]: \(message)"
            case .malformedResponse(let m): return "响应格式错误: \(m)"
            }
        }
    }

    public let socketPath: String
    public var timeout: TimeInterval

    public init(socketPath: String = GVGLClient.defaultSocketPath, timeout: TimeInterval = 30) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public static var defaultSocketPath: String {
        if let env = ProcessInfo.processInfo.environment["GVGL_SOCKET"], !env.isEmpty {
            return env
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gvgl/gvgl.sock").path
    }

    // MARK: - RPC

    public func call(_ method: String, app: String? = nil, since: UInt64? = nil) throws -> [String: Any] {
        var request: [String: Any] = ["method": method]
        if let app { request["app"] = app }
        if let since { request["since"] = since }
        let line = try String(data: JSONSerialization.data(withJSONObject: request), encoding: .utf8) ?? "{}"

        let fd = try connectSocket()
        defer { close(fd) }
        setReceiveTimeout(fd, timeout)

        // NDJSON protocol: requests must end with a newline (the daemon reads
        // until 0x0A; without it the request never completes).
        let payload = (line + "\n").data(using: .utf8)!
        let sent = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }
        if getenv("GVGL_DEBUG") != nil { fputs("gvgl-client: sent \(sent) bytes of \(payload.count)\n", stderr) }

        let response = try readLine(fd, timeout: timeout)
        if getenv("GVGL_DEBUG") != nil { fputs("gvgl-client: got \(response.count) bytes\n", stderr) }
        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw ClientError.malformedResponse(String(data: response, encoding: .utf8) ?? "?")
        }
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "unknown"
            let message = error["message"] as? String ?? ""
            throw ClientError.daemonError(code: code, message: message)
        }
        return json
    }

    public func getFrame(app: String? = nil) throws -> GVGLFrame {
        let json = try call("get_frame", app: app)
        guard let result = json["result"] else {
            throw ClientError.malformedResponse("missing result")
        }
        return try decode(GVGLFrame.self, from: result)
    }

    public func getFrameSince(_ since: UInt64, app: String? = nil) throws -> (frame: GVGLFrame?, changedApps: [String]) {
        let json = try call("get_frame", app: app, since: since)
        guard let result = json["result"] as? [String: Any] else {
            throw ClientError.malformedResponse("missing result")
        }
        if (result["event"] as? String) == "no_change" {
            return (nil, [])
        }
        guard let frameValue = result["frame"] else {
            throw ClientError.malformedResponse("missing frame")
        }
        let frame = try decode(GVGLFrame.self, from: frameValue)
        let apps = result["changed_apps"] as? [String] ?? []
        return (frame, apps)
    }

    public func getStatus() throws -> [String: Any] {
        let json = try call("get_status")
        return json["result"] as? [String: Any] ?? json
    }

    /// Typed status (get_status payload; snake_case keys decoded).
    public struct DaemonStatus: Codable, Equatable {
        public var monitoredApps: Int
        public var version: UInt64
        public var permissionGranted: Bool
        public var uptime: TimeInterval
        public var socket: String
        public var frameStatus: String

        public init(monitoredApps: Int, version: UInt64, permissionGranted: Bool,
                    uptime: TimeInterval, socket: String, frameStatus: String) {
            self.monitoredApps = monitoredApps
            self.version = version
            self.permissionGranted = permissionGranted
            self.uptime = uptime
            self.socket = socket
            self.frameStatus = frameStatus
        }
    }

    public func getStatusTyped() throws -> DaemonStatus {
        let json = try call("get_status")
        guard let result = json["result"] else {
            throw ClientError.malformedResponse("missing result")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DaemonStatus.self, from: data)
    }

    public struct SubscribeEvent {
        public var event: String
        public var version: UInt64?
        public var changedApps: [String]
    }

    /// Long-lived subscription. Blocking: runs until `cancel()` or the
    /// connection dies. Call on a background thread.
    public final class Subscription: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        private var stopped = false

        init(fd: Int32) { self.fd = fd }

        public func cancel() {
            lock.lock()
            stopped = true
            lock.unlock()
            shutdown(fd, SHUT_RDWR)
        }

        fileprivate var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
    }

    public func subscribe(since: UInt64? = nil,
                          onEvent: @escaping (SubscribeEvent) -> Void,
                          onError: @escaping (Error) -> Void) -> Subscription {
        let fd: Int32
        do {
            fd = try connectSocket()
        } catch {
            onError(error)
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            return Subscription(fd: sock)
        }
        let sub = Subscription(fd: fd)
        var request: [String: Any] = ["method": "subscribe"]
        if let since { request["since"] = since }
        if let line = try? String(data: JSONSerialization.data(withJSONObject: request), encoding: .utf8) {
            let payload = (line + "\n").data(using: .utf8)!
            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }
        }
        DispatchQueue.global().async {
            while !sub.isStopped {
                do {
                    let data = try Self.readLine(fd, timeout: 120)
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    var event = SubscribeEvent(event: json["event"] as? String ?? "?", version: nil, changedApps: json["changed_apps"] as? [String] ?? [])
                    if let v = json["version"] as? NSNumber {
                        event.version = v.uint64Value
                    }
                    onEvent(event)
                } catch {
                    if !sub.isStopped { onError(error) }
                    break
                }
            }
            close(fd)
        }
        return sub
    }

    // MARK: - Socket plumbing

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.connectionFailed(String(cString: strerror(errno))) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: Int8.self, capacity: 108) { dst in
                strlcpy(dst, socketPath, 108)
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            close(fd)
            throw ClientError.connectionFailed(String(cString: strerror(errno)))
        }
        return fd
    }

    private func setReceiveTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func readLine(_ fd: Int32, timeout: TimeInterval) throws -> Data {
        try Self.readLine(fd, timeout: timeout)
    }

    private static func readLine(_ fd: Int32, timeout: TimeInterval) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var data = Data()
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw ClientError.connectionFailed("读取超时")
                }
                throw ClientError.connectionFailed(String(cString: strerror(errno)))
            }
            if n == 0 {
                // EOF: tolerant like the reference python client — return
                // whatever was buffered (line may lack a trailing newline).
                if data.isEmpty {
                    throw ClientError.connectionFailed("连接已关闭")
                }
                return data
            }
            data.append(contentsOf: buffer[0..<n])
            if data.contains(0x0A) { break }
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder.gvgl.decode(type, from: data)
    }
}
