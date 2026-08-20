import AppKit
import Foundation

/// Tracks app launch/terminate via NSWorkspace notifications.
public final class WorkspaceTracker: @unchecked Sendable {
    public typealias AppHandler = (NSRunningApplication) -> Void

    private let onLaunched: AppHandler
    private let onTerminated: AppHandler
    private let onActivated: AppHandler?
    private var tokens: [NSObjectProtocol] = []

    public init(
        onLaunched: @escaping AppHandler,
        onTerminated: @escaping AppHandler,
        onActivated: AppHandler? = nil
    ) {
        self.onLaunched = onLaunched
        self.onTerminated = onTerminated
        self.onActivated = onActivated
    }

    public func start() {
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.onLaunched(app)
            }
        })
        tokens.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.onTerminated(app)
            }
        })
        if let onActivated {
            tokens.append(nc.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    onActivated(app)
                }
            })
        }
    }

    public func stop() {
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        tokens.removeAll()
    }

    /// All running apps that can own windows (regular + accessory activation policies).
    public static func runningWindowedApps(excluding pids: Set<Int32> = []) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && !pids.contains($0.processIdentifier)
        }
    }
}
