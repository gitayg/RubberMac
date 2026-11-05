import AppKit
import Synchronization

// The Dock's icons, through Accessibility. Asked what's at a point, the Dock answers in a tenth of a millisecond and
// only for its own icons, so it can be asked on every click; while it's hidden its icons sit below the screen's edge,
// where no click lands.
enum DockItems {
    struct Item: Equatable {
        let url: URL
        // In Accessibility coordinates.
        let frame: CGRect
    }

    private static let timeout: Float = 0.1
    private static let dock = Mutex<(pid: pid_t, element: AXUIElement)?>(nil)

    // Main thread: finds the Dock again, as after it restarts.
    static func refresh() {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let element = pid.map { pid -> (pid_t, AXUIElement) in
            let element = AX.app(pid)
            AXUIElementSetMessagingTimeout(element, timeout)
            return (pid, element)
        }
        dock.withLock { $0 = element }
    }

    // Any thread: the icon of a running app at this point, if the click lands on it. Something over the Dock there,
    // like the Alt-Tab grid, gets the click instead; the system-wide hit test, unlike the Dock's own, knows that.
    static func runningApp(at point: CGPoint) -> Item? {
        guard let (pid, app) = dock.withLock({ $0 }), let icon = element(at: point, in: app),
              AX.string(icon, kAXSubroleAttribute) == "AXApplicationDockItem",
              AX.bool(icon, "AXIsApplicationRunning") == true,
              let url = url(of: icon), let frame = AX.frame(of: icon) else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var owner: pid_t = 0
        guard let top = element(at: point, in: system), AXUIElementGetPid(top, &owner) == .success, owner == pid else { return nil }
        return Item(url: url, frame: frame)
    }

    private static func element(at point: CGPoint, in root: AXUIElement) -> AXUIElement? {
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit)
        if error == .invalidUIElement { DispatchQueue.main.async { refresh() } }
        return error == .success ? hit : nil
    }

    private static func url(of icon: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(icon, kAXURLAttribute as CFString, &value) == .success else { return nil }
        return (value as? URL)?.standardizedFileURL
    }
}
