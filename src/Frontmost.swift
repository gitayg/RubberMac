import AppKit
import Synchronization

// The frontmost app, readable from the keyboard tap's own thread. NSWorkspace keeps it current only on the main
// thread, so this copies it there on every app switch.
enum Frontmost {
    private static let current = Mutex<(bundleID: String?, pid: pid_t)>((nil, 0))
    private static let ownKey = Mutex(false)
    private static var observer: NSObjectProtocol?

    static var bundleID: String? { current.withLock { $0.bundleID } }
    static var pid: pid_t { current.withLock { $0.pid } }
    // One of RubberMAC's own windows has the keyboard, which the address bar and the writing pad do with another app in front.
    static var ownWindowIsKey: Bool { ownKey.withLock { $0 } }

    // On the main thread, before the tap starts.
    static func start() {
        guard observer == nil else { return }
        set(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            set(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        for (name, isKey) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                ownKey.withLock { $0 = isKey }
            }
        }
    }

    private static func set(_ app: NSRunningApplication?) {
        current.withLock { $0 = (app?.bundleIdentifier, app?.processIdentifier ?? 0) }
    }
}
