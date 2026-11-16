import Foundation
import GVGLCore
import GVGLQuery

/// What the executor needs from the daemon: a frame to locate targets in, and a
/// cheap version counter to know whether the desktop reacted.
public protocol FrameSource: AnyObject {
    func frame(app: String?) throws -> GVGLFrame
    func version() throws -> UInt64
    func status() throws -> GVGLClient.DaemonStatus
}

public final class SocketFrameSource: FrameSource {
    public let socketPath: String
    private let client: GVGLClient

    public init(socketPath: String) {
        self.socketPath = socketPath
        self.client = GVGLClient(socketPath: socketPath)
    }

    public func frame(app: String? = nil) throws -> GVGLFrame {
        try client.getFrame(app: app)
    }

    /// `get_status` is tiny; polling it is how the executor notices a change
    /// without pulling multi-megabyte frames every 80ms.
    public func version() throws -> UInt64 {
        try client.getStatusTyped().version
    }

    public func status() throws -> GVGLClient.DaemonStatus {
        try client.getStatusTyped()
    }
}

public struct ChangeObservation: Sendable {
    public var version: UInt64
    public init(version: UInt64) { self.version = version }
}

public enum ChangeWaiter {
    /// Blocks until the daemon's model version exceeds `since`, or times out.
    /// A change means *something* on the desktop changed; whether it was this
    /// action is decided by the caller from element state.
    public static func wait(source: FrameSource, since: UInt64,
                            timeout: TimeInterval, poll: TimeInterval = 0.08) -> ChangeObservation? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = try? source.version(), current > since {
                return ChangeObservation(version: current)
            }
            Thread.sleep(forTimeInterval: poll)
        }
        if let current = try? source.version(), current > since {
            return ChangeObservation(version: current)
        }
        return nil
    }
}
