import AppKit

// Dims the screens a few seconds before the warning, then shows a countdown banner for the
// last `Settings.warnSeconds` before the screen saver (and lock) starts.
final class LockWarning {
    static let dimLead: TimeInterval = 5
    static let dimLevel = 0.4

    private let monitor = IdleMonitor()
    private let panel = WarningPanel()
    private let dimmer = ScreenDimmer()
    private let timeoutOverride: TimeInterval?
    private var timer: Timer?

    init(timeoutOverride: TimeInterval?) {
        self.timeoutOverride = timeoutOverride
    }

    var saverTimeout: TimeInterval { timeoutOverride ?? monitor.saverTimeout() }

    func start() {
        log("lock warning: \(Settings.warnEnabled ? "on" : "off"), \(Settings.warnSeconds)s, dim \(Settings.dimEnabled ? "on" : "off")"
            + (timeoutOverride.map { ", test timeout \(Int($0))s" } ?? ""))
        tick()
    }

    // Re-evaluate immediately after a settings change.
    func refresh() {
        timer?.invalidate()
        tick()
    }

    private func schedule(_ seconds: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let window = TimeInterval(Settings.warnSeconds)
        let lead = window + (Settings.dimEnabled ? Self.dimLead : 0)
        let timeout = saverTimeout
        let idle = monitor.idleSeconds()
        let remaining = timeout - idle
        let suppressed = !Settings.warnEnabled || timeout <= lead || monitor.isLocked
            || monitor.saverRunning || monitor.displaySleepBlocked()

        if !suppressed && remaining > 0 && remaining <= lead {
            if Settings.dimEnabled && !dimmer.isDimmed {
                log("dimming: idle \(Int(idle))s")
                dimmer.dim(to: Self.dimLevel, over: 2)
            }
            if remaining <= window {
                if !panel.isShown { log("warning shown: idle \(Int(idle))s, screen saver at \(Int(timeout))s") }
                panel.show(secondsLeft: Int(remaining.rounded(.up)))
            }
            schedule(0.25)
            return
        }

        if dimmer.isDimmed { dimmer.restore() }
        if panel.isShown { log(remaining <= 0 ? "warning ended: screen saver due" : "warning cancelled: activity") }
        panel.hide()
        // Idle time grows at most 1s per second, so sleep until the dim/warning window could open.
        schedule(suppressed || remaining <= 0 ? 5 : min(max(remaining - lead, 0.25), 30))
    }
}
