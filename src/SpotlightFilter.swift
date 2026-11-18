import AppKit
import Carbon.HIToolbox

// Spotlight searches only apps: each time its search bar opens, RubberMAC presses ⌘1 in it, as the MacRumors thread
// suggests, so the results are apps and nothing else. A second ⌘1 changes nothing, Esc goes back to everything, and
// Spotlight doesn't keep the filter for next time. Spotlight wipes a letter that reaches it while it switches to apps
// (about 70-200 ms after the shortcut), so keys typed into it until then are held (SpotlightFilterHold) and handed
// to it once the switch is done. Off unless turned on; while off nothing is watched and nothing held.
final class SpotlightFilter: Feature {
    static let shared = SpotlightFilter()
    static let uiBundleID = "com.apple.campo"
    static let fieldID = "SpotlightSearchField"

    private(set) var watcher: SpotlightFilterWatcher?
    // In the keyboard tap, last (AppDelegate), so it holds keys as the other handlers let them through.
    let keys = SpotlightFilterKeys()
    private var tokens: [NSObjectProtocol] = []
    private var started = false
    // The switch, swapped out by the self-test so it never writes the real setting.
    var isOn: () -> Bool = { Settings.spotlightAppsOnlyEnabled }

    var wantsAccess: Bool { isOn() }
    var isWatching: Bool { watcher != nil || !tokens.isEmpty }

    func start() {
        started = true
        apply()
    }

    // An observer made before Accessibility was granted gets nothing.
    func restartTaps() {
        guard started, isOn() else { return }
        watcher = nil
        attach()
    }

    func apply() {
        guard started else { return }
        if isOn() { turnOn() } else { turnOff() }
    }

    private func turnOn() {
        if tokens.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            tokens = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in self?.changed(note) }
            }
        }
        if watcher == nil { attach() }
        keys.isEnabled = true
    }

    private func turnOff() {
        keys.isEnabled = false
        keys.hold.cancel()
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens = []
        watcher = nil
    }

    // Spotlight's process starting again gets a new watcher; it may not answer Accessibility for a moment.
    private func changed(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.uiBundleID else { return }
        if note.name == NSWorkspace.didTerminateApplicationNotification {
            if watcher?.pid == app.processIdentifier { watcher = nil }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.isOn(), self.watcher == nil else { return }
                self.attach()
            }
        }
    }

    private func attach() {
        guard AX.isTrusted else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.uiBundleID).first else {
            return log("spotlight apps only: Spotlight's search bar (\(Self.uiBundleID)) isn't running")
        }
        let pid = app.processIdentifier
        watcher = SpotlightFilterWatcher(pid: pid) {
            log("spotlight: search bar opened → ⌘1, apps only")
            Self.pressAppsKey(pid)
        }
        guard let watcher else { return log("spotlight apps only: can't watch Spotlight's search bar (pid \(pid))") }
        let hold = keys.hold
        hold.replay = { events in events.forEach { $0.postToPid(pid) } }
        hold.onRelease = { count, ms, reason in
            guard count > 0 else { return }
            DispatchQueue.main.async { log("spotlight: \(count) key events held \(ms) ms while it switched to apps, then passed on (\(reason))") }
        }
        watcher.onFocused = { hold.begin() }
        watcher.openings.onSettled = { step in if step == .press { hold.pressed() } else { hold.cancel() } }
        watcher.openings.onSwitched = { hold.switched() }
    }

    // ⌘1 straight to Spotlight's process, so it can't land in another app whatever has the keyboard. Typed through
    // the keyboard instead it kept a letter typed right behind it no better (measured), as Spotlight's switch to apps
    // wipes a letter that reaches it mid-switch whichever way the ⌘1 came.
    static func pressAppsKey(_ pid: pid_t) {
        appsKeyEvents().forEach { $0.postToPid(pid) }
    }

    // ⌘1 down and up, with ⌘ alone on them.
    static func appsKeyEvents() -> [CGEvent] {
        let source = CGEventSource(stateID: .hidSystemState)
        return [true, false].compactMap { down in
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_1), keyDown: down)
            event?.flags = .maskCommand
            return event
        }
    }

    // The search field's placeholder while it shows only apps: "Applications", the Applications folder's own name.
    static var appsTitle: String { FileManager.default.displayName(atPath: "/Applications") }

    static func selfTestReport() -> String { SpotlightFilterSelfTest.report() }
    static func liveSelfTestReport() -> String { SpotlightFilterLive.report() }
}
