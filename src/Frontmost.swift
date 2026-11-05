import AppKit
import Synchronization

// The frontmost app, readable from the keyboard tap's own thread. NSWorkspace keeps it current only on the main
// thread, so this copies it there on every app switch.
enum Frontmost {
    private static let current = Mutex<(bundleID: String?, pid: pid_t)>((nil, 0))
    private static var observer: NSObjectProtocol?

    static var bundleID: String? { current.withLock { $0.bundleID } }
    static var pid: pid_t { current.withLock { $0.pid } }

    // On the main thread, before the tap starts.
    static func start() {
        guard observer == nil else { return }
        set(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            set(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    private static func set(_ app: NSRunningApplication?) {
        current.withLock { $0 = (app?.bundleIdentifier, app?.processIdentifier ?? 0) }
    }
}
