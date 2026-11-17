import AppKit

// One mode change waiting for an answer: applied for this login session only, saved for good on Keep, and put back
// exactly on Go Back, when the countdown runs out, or when another screen's mode is chosen meanwhile. A screen unplugged
// during its countdown is put back when it returns still in the mode nobody kept. The clock is passed in, so the
// self-test runs the countdown without waiting; whoever owns this calls tick() as time passes.
final class ScreenResolutionChange {
    static let countdown: TimeInterval = 15
    // Missing this long, a screen is unplugged rather than settling into its new mode.
    static let unplugGrace: TimeInterval = 2

    struct Pending: Equatable {
        let display: CGDirectDisplayID
        let key: String
        let name: String
        let previous: ScreenResolution.Mode
        let previousTitle: String
        var chosen: ScreenResolution.Mode
        var chosenTitle: String
        var deadline: Date
        var goneSince: Date?
    }

    enum Outcome: Equatable {
        case kept
        // Keep was answered but macOS didn't save it, so it lasts until logging out.
        case keptForSession
        case wentBack
        case timedOut
        case unplugged
        // The old mode couldn't be put back.
        case failed
    }

    let switcher: ScreenResolutionSwitcher
    let clock: () -> Date
    var onShow: (Pending, Int) -> Void = { _, _ in }
    var onEnd: (Pending, Outcome) -> Void = { _, _ in }
    // RubberMAC's log; the self-test keeps its made-up screens out of it.
    var report: (String) -> Void = { log($0) }

    private(set) var pending: Pending?
    // Unplugged during its countdown, not back yet.
    private(set) var awaiting: Pending?

    init(switcher: ScreenResolutionSwitcher, clock: @escaping () -> Date) {
        self.switcher = switcher
        self.clock = clock
    }

    var secondsLeft: Int {
        guard let pending else { return 0 }
        return max(0, Int(pending.deadline.timeIntervalSince(clock()).rounded(.up)))
    }

    // Whether the screen is now in that mode, waiting for an answer.
    @discardableResult
    func choose(_ mode: ScreenResolution.Mode, on display: CGDirectDisplayID, name: String) -> Bool {
        if var pending, pending.display == display {
            // Choosing the mode it had is answering Go Back.
            if mode == pending.previous {
                goBack()
                return false
            }
            guard mode != pending.chosen else { return true }
            guard apply(mode, display, name) else { return false }
            pending.chosen = mode
            pending.chosenTitle = ScreenResolution.title(of: mode, among: switcher.modes(of: display))
            pending.deadline = clock().addingTimeInterval(Self.countdown)
            self.pending = pending
            onShow(pending, secondsLeft)
            return true
        }
        // Another screen's change wasn't kept, so it goes back before this one starts.
        if pending != nil { goBack() }
        guard let previous = switcher.current(of: display), previous != mode else { return false }
        let key = switcher.key(of: display)
        if awaiting?.key == key { awaiting = nil }
        guard apply(mode, display, name) else { return false }
        let modes = switcher.modes(of: display)
        let started = Pending(display: display, key: key, name: name, previous: previous,
                              previousTitle: ScreenResolution.title(of: previous, among: modes), chosen: mode,
                              chosenTitle: ScreenResolution.title(of: mode, among: modes),
                              deadline: clock().addingTimeInterval(Self.countdown))
        pending = started
        onShow(started, secondsLeft)
        return true
    }

    func keep() {
        guard let pending else { return }
        finish(switcher.apply(pending.chosen, to: pending.display, permanently: true) ? .kept : .keptForSession)
    }

    func goBack() { putBack(.wentBack) }

    func tick() {
        guard var pending else { return }
        let now = clock()
        pending.goneSince = switcher.displays().contains(pending.display) ? nil : pending.goneSince ?? now
        self.pending = pending
        if let gone = pending.goneSince, now.timeIntervalSince(gone) >= Self.unplugGrace || now >= pending.deadline {
            awaiting = pending
            finish(.unplugged)
        } else if now >= pending.deadline {
            putBack(.timedOut)
        } else {
            onShow(pending, secondsLeft)
        }
    }

    // A screen came or went, or changed: one unplugged during its countdown is put back if it returns as it was left.
    func screensChanged() {
        if let awaiting, let back = switcher.displays().first(where: { switcher.key(of: $0) == awaiting.key }) {
            self.awaiting = nil
            let modes = switcher.modes(of: back)
            if let now = switcher.current(of: back), now.sameMode(as: awaiting.chosen),
               let previous = modes.first(where: { $0 == awaiting.previous }) ?? modes.first(where: { $0.sameMode(as: awaiting.previous) }) {
                let done = switcher.apply(previous, to: back, permanently: false)
                report("resolution: \(awaiting.name) is back in \(awaiting.chosenTitle), which wasn't kept: "
                    + (done ? "put back \(awaiting.previousTitle)" : "macOS didn't put back \(awaiting.previousTitle)"))
            }
        }
        tick()
    }

    private func apply(_ mode: ScreenResolution.Mode, _ display: CGDirectDisplayID, _ name: String) -> Bool {
        let done = switcher.apply(mode, to: display, permanently: false)
        let title = ScreenResolution.title(of: mode, among: switcher.modes(of: display))
        report("resolution: \(name): " + (done ? "\(title) for this session, kept only if confirmed within \(Int(Self.countdown)) s"
                                             : "macOS didn't switch to \(title)"))
        return done
    }

    private func putBack(_ outcome: Outcome) {
        guard let pending else { return }
        guard switcher.displays().contains(pending.display) else {
            awaiting = pending
            return finish(.unplugged)
        }
        finish(switcher.apply(pending.previous, to: pending.display, permanently: false) ? outcome : .failed)
    }

    private func finish(_ outcome: Outcome) {
        guard let ended = pending else { return }
        pending = nil
        onEnd(ended, outcome)
    }
}
