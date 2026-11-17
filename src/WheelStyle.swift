import AppKit

// A mouse wheel that works as on Windows: the classic direction while the trackpad keeps natural scrolling, the same
// distance for each notch however fast it turns, and ⌘ + wheel to zoom, like Ctrl + wheel. Trackpad and Magic Mouse
// swipes are left alone.
final class WheelStyle: Feature {
    static let shared = WheelStyle()

    // In the mouse tap, after WheelDragScroll and before WheelSpeed, so the wheel speed scales what this hands on.
    let handler: TapHandler
    var wantsAccess: Bool { Switches.stored.any }

    let wheel: WheelStyleHandler
    let menus: ZoomMenuCache

    private init() {
        let menus = ZoomMenuCache()
        self.menus = menus
        wheel = WheelStyleHandler(zoom: WheelZoom(lookup: menus.lookup, press: ZoomKeys.press))
        handler = wheel
        // Already set as the mouse tap first starts, which is before start().
        setSwitches()
    }

    // An app's menus are read as it comes to the front, so the first ⌘ + wheel there already finds its zoom.
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.readMenus(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.menus.forget(app.processIdentifier)
        }
        readMenus(NSWorkspace.shared.frontmostApplication)
        let on = Switches.stored
        log("wheel style: classic \(on.classic ? "on" : "off"), steady \(on.steady ? "on" : "off"), ⌘ zoom \(on.zoom ? "on" : "off"); "
            + "natural scrolling \(Self.naturalScrolling() ? "on" : "off")")
    }

    // Its handler rides in AppDelegate's mouse tap, which AppDelegate starts again itself.
    func restartTaps() {}

    // After any of its switches on the Mouse page changes.
    func apply() {
        setSwitches()
        readMenus(NSWorkspace.shared.frontmostApplication)
    }

    private func setSwitches() {
        let on = Switches.stored
        wheel.classic = on.classic
        wheel.steady = on.steady
        wheel.zoomOn = on.zoom
    }

    private func readMenus(_ app: NSRunningApplication?) {
        guard wheel.zoomOn, let app, WheelZoom.leftAlone(app.bundleIdentifier) == nil else { return }
        _ = menus.lookup(app.processIdentifier)
    }
}
