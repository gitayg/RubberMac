import AppKit
import ApplicationServices

// Tells the address bar when the strip may need to move or change: from an Accessibility observer on Finder, its
// focused window changing and the strip's window moving, resizing, changing folder (its title), minimizing or
// closing; from NSWorkspace, app and Space switches; and screens changing. Runs on the main thread.
final class FinderAddressBarWatcher {
    enum Change { case frame, window }

    private static let appNotifications = [kAXFocusedWindowChangedNotification]
    private static let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXTitleChangedNotification,
                                              kAXWindowMiniaturizedNotification, kAXUIElementDestroyedNotification]

    var onChange: (Change) -> Void = { _ in }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var observer: AXObserver?
    private var observed: pid_t = 0
    private var window: AXUIElement?

    func start() {
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        let changed: (Notification) -> Void = { [weak self] _ in self?.onChange(.window) }
        observers = [
            (ws, ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: changed)),
            (ws, ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: changed)),
            (nc, nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: changed)),
        ]
    }

    func stop() {
        observers.forEach { center, token in center.removeObserver(token) }
        observers = []
        unobserve()
    }

    // Observes Finder; a new pid means Finder was relaunched. Call before reading its focused window, so a switch
    // either lands before the read or arrives as a notification.
    func follow(_ pid: pid_t) {
        guard pid != observed else { return }
        unobserve()
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, _, notification, context in
            guard let context else { return }
            Unmanaged<FinderAddressBarWatcher>.fromOpaque(context).takeUnretainedValue().received(notification as String)
        }, &created) == .success, let created else { return }
        let app = AX.app(pid)
        AXUIElementSetMessagingTimeout(app, FinderBrowserWindow.timeout)
        for name in Self.appNotifications {
            guard AXObserverAddNotification(created, app, name as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success
            else { return }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observed = pid
    }

    // The window the strip is on now, or nil; only its moves, title and the like are reported. It already carries
    // the short timeout.
    func watch(_ window: AXUIElement?) {
        guard let observer, !Self.same(window, self.window) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let old = self.window { Self.windowNotifications.forEach { AXObserverRemoveNotification(observer, old, $0 as CFString) } }
        if let window { Self.windowNotifications.forEach { AXObserverAddNotification(observer, window, $0 as CFString, refcon) } }
        self.window = window
    }

    private func received(_ notification: String) {
        onChange(notification == kAXWindowMovedNotification || notification == kAXWindowResizedNotification ? .frame : .window)
    }

    private func unobserve() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        observed = 0
        window = nil
    }

    private static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return CFEqual(a, b)
        default: return false
        }
    }
}
