import AppKit
import ApplicationServices

// Reports each window that gets focus: app switches come from NSWorkspace, and window switches inside the
// frontmost app from an Accessibility observer on that app. Runs on the main thread.
final class FocusTracker {
    // A hung app would otherwise block the main thread, and with it the keyboard tap, for the 6 s default.
    private static let timeout: Float = 0.25

    var onFocus: (CGWindowID) -> Void = { _ in }

    private var activation: NSObjectProtocol?
    private var observer: AXObserver?
    private var observed: pid_t = 0

    // The frontmost app and its focused window. The system-wide focused application can't stand in for
    // NSWorkspace here: it reports no value while Chrome or Claude is in front.
    static func focused() -> (pid: pid_t, window: CGWindowID?)? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return (pid, focusedWindow(of: pid))
    }

    func start() {
        guard activation == nil else { return }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.follow(app.processIdentifier)
        }
        if let app = NSWorkspace.shared.frontmostApplication { follow(app.processIdentifier) }
        log("focus tracking: on")
    }

    func stop() {
        guard let activation else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(activation)
        self.activation = nil
        unobserve()
        log("focus tracking: off")
    }

    // Observe first, then read: a window switch either lands before the read or arrives as a notification.
    private func follow(_ pid: pid_t) {
        if pid != observed { observe(pid) }
        if let id = Self.focusedWindow(of: pid) { onFocus(id) }
    }

    private func observe(_ pid: pid_t) {
        unobserve()
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, window, _, context in
            guard let context, let id = AX.windowID(of: window) else { return }
            Unmanaged<FocusTracker>.fromOpaque(context).takeUnretainedValue().onFocus(id)
        }, &created) == .success, let created else { return }
        let app = AX.app(pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        guard AXObserverAddNotification(created, app, kAXFocusedWindowChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observed = pid
    }

    private func unobserve() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        observed = 0
    }

    private static func focusedWindow(of pid: pid_t) -> CGWindowID? {
        let app = AX.app(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success else { return nil }
        return AX.windowID(of: window as! AXUIElement)
    }
}
