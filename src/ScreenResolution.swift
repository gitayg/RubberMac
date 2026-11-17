import AppKit

// The resolution the Mac really sends to each screen, not only how big things look, picked per screen; a new one is
// kept only once you say so, and goes back by itself if you can't (a screen that shows nothing).
final class ScreenResolution: Feature {
    static let shared = ScreenResolution()
    static let note = "The resolution the Mac sends to the screen, not just how big things look"
    static let tickInterval: TimeInterval = 0.25

    // What each popup item carries.
    final class Pick: NSObject {
        let display: CGDirectDisplayID
        let name: String
        let mode: Mode

        init(display: CGDirectDisplayID, name: String, mode: Mode) {
            self.display = display
            self.name = name
            self.mode = mode
        }
    }

    let change: ScreenResolutionChange
    let presenter: ScreenResolutionPresenter
    private var timer: Timer?
    private var started = false

    init(switcher: ScreenResolutionSwitcher = ScreenResolutionQuartz(), clock: @escaping () -> Date = Date.init,
         presenter: ScreenResolutionPresenter = ScreenResolutionWindows()) {
        change = ScreenResolutionChange(switcher: switcher, clock: clock)
        self.presenter = presenter
        change.onShow = { [weak self] pending, seconds in self?.show(pending, seconds) }
        change.onEnd = { [weak self] pending, outcome in self?.ended(pending, outcome) }
        presenter.onKeep = { [weak self] in self?.change.keep() }
        presenter.onGoBack = { [weak self] in self?.change.goBack() }
    }

    var wantsAccess: Bool { false }
    var isCounting: Bool { timer != nil }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.change.screensChanged()
        }
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.quitting()
        }
    }

    func restartTaps() {}

    func choose(_ pick: Pick) {
        change.choose(pick.mode, on: pick.display, name: pick.name)
    }

    // Not answered when RubberMAC quits, it isn't kept.
    func quitting() {
        change.goBack()
    }

    private func show(_ pending: ScreenResolutionChange.Pending, _ seconds: Int) {
        if timer == nil {
            // In every run loop mode, so the countdown still runs out while a menu is open.
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in self?.change.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        presenter.show(ScreenResolutionQuestion(display: pending.display, name: pending.name, chosen: pending.chosenTitle,
                                                previous: pending.previousTitle, secondsLeft: seconds))
    }

    private func ended(_ pending: ScreenResolutionChange.Pending, _ outcome: ScreenResolutionChange.Outcome) {
        timer?.invalidate()
        timer = nil
        presenter.hide()
        let what: String
        switch outcome {
        case .kept: what = "kept \(pending.chosenTitle)"
        case .keptForSession: what = "kept \(pending.chosenTitle), but macOS didn't save it: it lasts until logging out"
        case .wentBack: what = "went back to \(pending.previousTitle)"
        case .timedOut: what = "no answer in \(Int(ScreenResolutionChange.countdown)) s, went back to \(pending.previousTitle)"
        case .unplugged: what = "unplugged before an answer; \(pending.previousTitle) is put back when it returns in \(pending.chosenTitle)"
        case .failed: what = "macOS didn't put back \(pending.previousTitle); it stays at \(pending.chosenTitle) until logging out"
        }
        change.report("resolution: \(pending.name): \(what)")
    }
}
