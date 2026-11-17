import AppKit
import ApplicationServices

// Calls back whenever the window in front may have changed: app switches, hiding and Space switches from NSWorkspace,
// and inside the frontmost app focus moving between windows and windows opening, closing and being minimized, from an
// Accessibility observer. Moving and resizing aren't watched: each overlay covers its whole screen and keeps its place
// in the stack, so a window that moves needs nothing. Main thread.
final class BackgroundDimWatcher {
    var onChange: () -> Void = {}
    var onScreens: () -> Void = {}
    // Accessibility notifications received, by name, for the self-test.
    private(set) var received: [String: Int] = [:]

    private let ownPID: pid_t
    private var tokens: [NSObjectProtocol] = []
    private var observer: AXObserver?
    private var observed: pid_t = 0
    private var window: AXUIElement?

    private static let appNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                                           kAXWindowCreatedNotification, kAXWindowMiniaturizedNotification,
                                           kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification]

    init(ownPID: pid_t) {
        self.ownPID = ownPID
    }

    var isRunning: Bool { !tokens.isEmpty }
    // The app being watched: the one in front, or the one before RubberMAC came to the front.
    var app: pid_t { observed }

    func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.frontChanged() })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in self?.onScreens() })
        follow()
    }

    func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        tokens = []
        unobserve()
    }

    // Once Accessibility is granted, an observer made before it got nothing.
    func restart() {
        guard isRunning else { return }
        unobserve()
        follow()
    }

    // Also told when the front window closes; nil stops that.
    func watch(_ element: AXUIElement?) {
        guard let observer else { return }
        if let window, let element, CFEqual(window, element) { return }
        if let window { AXObserverRemoveNotification(observer, window, kAXUIElementDestroyedNotification as CFString) }
        window = element
        if let element {
            AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func frontChanged() {
        follow()
        onChange()
    }

    private func follow() {
        guard let pid = BackgroundDimFront.frontApp(ownPID: ownPID, last: observed), pid != observed else { return }
        unobserve()
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, _, notification, context in
            guard let context else { return }
            let watcher = Unmanaged<BackgroundDimWatcher>.fromOpaque(context).takeUnretainedValue()
            watcher.received[notification as String, default: 0] += 1
            watcher.onChange()
        }, &created) == .success, let created else { return }
        let app = AX.app(pid)
        for name in Self.appNotifications {
            AXObserverAddNotification(created, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observed = pid
    }

    private func unobserve() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        observed = 0
        window = nil
    }
}
