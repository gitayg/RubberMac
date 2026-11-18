import AppKit
import ApplicationServices

// Spotlight's search bar as Accessibility announces it: a window of Spotlight's taking the keyboard (3-13 ms after the
// shortcut, before anyone can type), the bar's window being made, and focus moving in it. The bar belongs to Siri
// AI.app (com.apple.campo), though its windows are named "Siri". Main thread.
final class SpotlightFilterWatcher {
    // A hung Spotlight would otherwise hold up the main thread for the 6 s default.
    static let timeout: Float = 0.25
    private static let notifications = [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification,
                                        kAXFocusedUIElementChangedNotification]

    let pid: pid_t
    let openings: SpotlightFilterOpenings
    // Notifications received by name, for the self-test.
    private(set) var received: [String: Int] = [:]
    // A window of Spotlight's took the keyboard: told at once, with no Accessibility call that could wait on Spotlight.
    var onFocused: () -> Void = {}
    private let observer: AXObserver

    // nil without Accessibility, or while Spotlight's process is still starting up.
    init?(pid: pid_t, press: @escaping () -> Void) {
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, _, notification, context in
            guard let context else { return }
            Unmanaged<SpotlightFilterWatcher>.fromOpaque(context).takeUnretainedValue().notified(notification as String)
        }, &created) == .success, let created else { return nil }
        self.pid = pid
        observer = created
        openings = SpotlightFilterOpenings(uiPid: pid, read: { Self.bar(pid) }, press: press)
        openings.appsTitle = SpotlightFilter.appsTitle
        let element = AX.app(pid)
        AXUIElementSetMessagingTimeout(element, Self.timeout)
        for name in Self.notifications {
            guard AXObserverAddNotification(created, element, name as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success else { return nil }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func notified(_ name: String) {
        received[name, default: 0] += 1
        switch name {
        case kAXFocusedWindowChangedNotification: onFocused()
        case kAXWindowCreatedNotification: openings.windowCreated()
        default: openings.focusChanged()
        }
    }

    // Timeouts go on each element asked: set on the system-wide one, a timeout would become every call's in RubberMAC.
    static func bar(_ pid: pid_t) -> SpotlightFilterOpenings.Bar {
        var bar = SpotlightFilterOpenings.Bar()
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
           let value {
            var focused: pid_t = 0
            if AXUIElementGetPid(value as! AXUIElement, &focused) == .success { bar.focusedPid = focused }
        }
        let app = AX.app(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var element: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &element) == .success, let element else { return bar }
        let field = element as! AXUIElement
        AXUIElementSetMessagingTimeout(field, timeout)
        bar.fieldID = AX.string(field, kAXIdentifierAttribute)
        bar.placeholder = AX.string(field, kAXPlaceholderValueAttribute)
        return bar
    }
}
