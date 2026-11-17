import AppKit

// ⌘ + wheel zooms the front app, as Ctrl + wheel does on Windows: each notch presses the app's own Zoom In or Zoom Out
// once. Turning the wheel away from you zooms in, whatever Natural scrolling is set to. An app with nothing to zoom, or
// with a ⌘-scroll of its own, gets the scroll as it was.
final class WheelZoom {
    enum Outcome: Equatable {
        case passed(String)
        case zoomed(in: Bool)
        // Swallowed without a step: too soon after the last one, or not yet a notch's worth of a smooth wheel.
        case held
    }

    // Apps that zoom or pan on ⌘ + scroll themselves, smoothly; a step of RubberMAC's on top would fight theirs.
    static let ownZoom: Set<String> = [
        "com.figma.Desktop", "com.bohemiancoding.sketch3", "com.seriflabs.affinitydesigner2", "com.seriflabs.affinityphoto2",
        "com.seriflabs.affinitypublisher2", "com.adobe.Photoshop", "com.adobe.illustrator", "com.adobe.InDesign",
        "com.pixelmatorteam.pixelmator.x",
    ]

    // One step a notch, but at most one every 60 ms however fast the wheel spins: a hand turning notch by notch with ⌘
    // held sent them 57 to 150 ms apart (measured), and a free-spinning wheel one every 7 to 20 ms.
    static let interval: TimeInterval = 0.06
    // A smoothing driver sends a notch as many steps of less than a line: they make a step once they add up to a notch
    // as Steady counts one, and start again after a pause or a change of direction.
    static let notchPoints = Double(WheelNotch.lines * WheelNotch.pointsPerLine)
    static let pause: TimeInterval = 0.5

    var front: () -> (bundleID: String?, pid: pid_t) = { (Frontmost.bundleID, Frontmost.pid) }
    var lookup: (pid_t) -> ZoomLookup
    var press: (ZoomItem, pid_t) -> Void
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private var lastStep = -TimeInterval.infinity
    private var pixels = 0.0
    private var lastPixels = -TimeInterval.infinity

    init(lookup: @escaping (pid_t) -> ZoomLookup, press: @escaping (ZoomItem, pid_t) -> Void) {
        self.lookup = lookup
        self.press = press
    }

    // ⌘ and no other modifier, as Ctrl alone is on Windows.
    static func wants(_ flags: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == .maskCommand
    }

    // Why an app keeps its ⌘ + scroll, if it does, before its menus are looked at.
    static func leftAlone(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if AppLists.remote.contains(bundleID) { return "a remote desktop or VM" }
        if ownZoom.contains(bundleID) { return "zooms on ⌘-scroll itself" }
        if bundleID == Bundle.main.bundleIdentifier { return "RubberMAC itself" }
        return nil
    }

    // A wheel event with ⌘ alone held; anything but .passed is swallowed.
    func scroll(_ event: CGEvent, natural: Bool) -> Outcome {
        let app = front()
        if let reason = Self.leftAlone(app.bundleID) { return .passed(reason) }
        let turn = WheelNotch.deviceDirection(event, axis: 0, natural: natural)
        guard turn != 0 else { return .passed("no turn up or down") }
        let menu: ZoomMenu
        switch lookup(app.pid) {
        case .reading: return .passed("its menus are still being read")
        case .none: return .passed("no Zoom In and Zoom Out in its menus")
        case .found(let found): menu = found
        }
        let time = now()
        if !WheelNotch.isNotched(event) {
            let moved = Double(abs(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) * turn)
            if time - lastPixels > Self.pause || (pixels != 0 && (pixels > 0) != (moved > 0)) { pixels = 0 }
            lastPixels = time
            pixels += moved
            guard abs(pixels) >= Self.notchPoints else { return .held }
            pixels = 0
        }
        guard time - lastStep >= Self.interval else { return .held }
        lastStep = time
        press(turn > 0 ? menu.zoomIn : menu.zoomOut, app.pid)
        return .zoomed(in: turn > 0)
    }
}
