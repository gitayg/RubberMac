import AppKit
import ApplicationServices

// One app's new windows, from its Accessibility notifications: a window made, and focus moving to a window, as some
// apps don't announce new ones. Each window numbered above `since` is handed on once. Main thread.
final class OpenOnScreenObserver {
    // A hung app would otherwise hold up the main thread for the 6 s default.
    static let timeout: Float = 0.25
    private static let notifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]

    let app: NSRunningApplication
    var since: CGWindowID
    // Notifications received by name, and windows found by listing them, for the self-test.
    private(set) var received: [String: Int] = [:]
    private let observer: AXObserver
    private let onWindow: (AXUIElement, CGWindowID) -> Void
    private var seen = Set<CGWindowID>()

    // nil while the app can't be observed: without Accessibility, or while it's still starting up.
    init?(_ app: NSRunningApplication, since: CGWindowID, onWindow: @escaping (AXUIElement, CGWindowID) -> Void) {
        var created: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { _, element, notification, context in
            guard let context else { return }
            Unmanaged<OpenOnScreenObserver>.fromOpaque(context).takeUnretainedValue().notified(element, notification as String)
        }, &created) == .success, let created else { return nil }
        self.app = app
        self.since = since
        self.onWindow = onWindow
        observer = created
        let element = AX.app(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.timeout)
        for name in Self.notifications {
            guard AXObserverAddNotification(created, element, name as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success else { return nil }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    // The windows already there, which may have been made before the observer was.
    func scan() {
        let element = AX.app(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return }
        for window in (value as? [AXUIElement]) ?? [] {
            if hand(window) { received["listed", default: 0] += 1 }
        }
    }

    private func notified(_ element: AXUIElement, _ name: String) {
        received[name, default: 0] += 1
        hand(element)
    }

    @discardableResult
    private func hand(_ window: AXUIElement) -> Bool {
        guard let id = AX.windowID(of: window), id > since, seen.insert(id).inserted else { return false }
        onWindow(window, id)
        return true
    }
}
