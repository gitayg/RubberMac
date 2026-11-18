import Foundation

// One opening of Spotlight's search bar at a time: armed when Spotlight announces the bar's window as made (once per
// opening, measured), ⌘1 pressed once its search field has the keyboard, then nothing until the next window. Esc
// taking the filter off sends no such notice, so it stays off. After the ⌘1 it watches for the switch being done (the
// empty field's placeholder changing, "Search or Ask" to "Applications" here), so keys held meanwhile can go. No
// Accessibility here: the bar is read and the key pressed through closures, which the self-test swaps out.
final class SpotlightFilterOpenings {
    // What the bar looks like now: which process has the keyboard, and the element focused in Spotlight's.
    struct Bar: Equatable {
        var focusedPid: pid_t?
        var fieldID: String?
        var placeholder: String?
    }

    enum Step: Equatable {
        case wait, press, alreadyOn, expired
    }

    // The window is announced 55-115 ms after the shortcut and the field has the keyboard by then (measured); a
    // window whose field hasn't got it within this is something else of Siri's.
    static let armedFor: TimeInterval = 1.5

    static func step(sinceOpened: TimeInterval, bar: Bar, uiPid: pid_t, appsTitle: String?) -> Step {
        guard sinceOpened <= armedFor else { return .expired }
        guard bar.focusedPid == uiPid, bar.fieldID == SpotlightFilter.fieldID else { return .wait }
        if let appsTitle, bar.placeholder == appsTitle { return .alreadyOn }
        return .press
    }

    let uiPid: pid_t
    var read: () -> Bar
    var press: () -> Void
    var now: () -> Date = Date.init
    // The field's placeholder while it shows only apps and is empty ("Applications" here).
    var appsTitle: String?
    // Told how each opening ended (.press, .alreadyOn or .expired), and when the switch a ⌘1 started is done.
    var onSettled: (Step) -> Void = { _ in }
    var onSwitched: () -> Void = {}
    private(set) var opened: Date?
    // The placeholder when the ⌘1 went, and when, while the switch isn't seen done yet.
    private(set) var awaiting: (placeholder: String, since: Date)?
    private(set) var presses = 0
    private(set) var alreadyOn = 0
    private(set) var expired = 0

    init(uiPid: pid_t, read: @escaping () -> Bar, press: @escaping () -> Void) {
        self.uiPid = uiPid
        self.read = read
        self.press = press
    }

    func windowCreated() {
        opened = now()
        awaiting = nil
        check()
    }

    // Spotlight moves focus between the window and the field a dozen times as it opens and as it switches; outside
    // an opening and its switch this returns at once.
    func focusChanged() {
        if opened != nil { return check() }
        guard let awaiting else { return }
        guard now().timeIntervalSince(awaiting.since) <= Self.armedFor else {
            self.awaiting = nil
            return
        }
        let bar = read()
        guard bar.fieldID == SpotlightFilter.fieldID, bar.placeholder != awaiting.placeholder else { return }
        self.awaiting = nil
        onSwitched()
    }

    private func check() {
        guard let opened else { return }
        let bar = read()
        let step = Self.step(sinceOpened: now().timeIntervalSince(opened), bar: bar, uiPid: uiPid, appsTitle: appsTitle)
        switch step {
        case .wait: return
        case .press:
            presses += 1
            awaiting = (bar.placeholder ?? "", now())
            press()
        case .alreadyOn: alreadyOn += 1
        case .expired: expired += 1
        }
        self.opened = nil
        onSettled(step)
    }
}
