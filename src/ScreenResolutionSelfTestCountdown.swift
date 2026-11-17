import AppKit

// Part of --selftest resolution: the countdown on made-up screens with a made-up clock, and the feature wired to a
// recorder instead of windows.
extension ScreenResolution {
    // Screens that are only data: what they're in, and every mode change asked of them.
    final class FakeScreens: ScreenResolutionSwitcher {
        var connected: [CGDirectDisplayID] = []
        var keys: [CGDirectDisplayID: String] = [:]
        var lists: [CGDirectDisplayID: [Mode]] = [:]
        var now: [CGDirectDisplayID: Mode] = [:]
        var refuses = false
        var refusesToSave = false
        private(set) var asked: [String] = []

        func displays() -> [CGDirectDisplayID] { connected }
        func key(of display: CGDirectDisplayID) -> String { keys[display] ?? "\(display)" }
        func modes(of display: CGDirectDisplayID) -> [Mode] { lists[display] ?? [] }
        func current(of display: CGDirectDisplayID) -> Mode? { connected.contains(display) ? now[display] : nil }

        func apply(_ mode: Mode, to display: CGDirectDisplayID, permanently: Bool) -> Bool {
            asked.append("\(display): mode \(mode.id) \(permanently ? "saved" : "session")")
            guard connected.contains(display), !refuses, !(permanently && refusesToSave) else { return false }
            now[display] = mode
            return true
        }

        func forget() { asked = [] }
    }

    final class Recorder: ScreenResolutionPresenter {
        var onKeep: () -> Void = {}
        var onGoBack: () -> Void = {}
        private(set) var shown: [ScreenResolutionQuestion] = []
        private(set) var hidden = 0
        func show(_ question: ScreenResolutionQuestion) { shown.append(question) }
        func hide() { hidden += 1 }
    }

    // An ultrawide like this Mac's, at 100 Hz native, and a 4K screen beside it.
    static let wide: [Mode] = [mode(51, 3440, 1440, 3440, 1440, 100, native: true), mode(52, 3440, 1440, 3440, 1440, 60, native: true),
                               mode(44, 1920, 1080, 1920, 1080, 60), mode(42, 1920, 1080, 1920, 1080, 120), mode(15, 1280, 720, 1280, 720, 60)]
    static let side: [Mode] = [mode(1, 3840, 2160, 3840, 2160, 60, native: true), mode(2, 3840, 2160, 1920, 1080, 60, native: true)]

    static func fakeScreens() -> FakeScreens {
        let screens = FakeScreens()
        screens.connected = [5, 7]
        screens.keys = [5: "24739:4112:0", 7: "4268:41089:12345"]
        screens.lists = [5: wide, 7: side]
        screens.now = [5: wide[0], 7: side[1]]
        return screens
    }

    // MARK: The countdown

    static func countdownChecks(_ check: Check) {
        var time = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func at(_ seconds: TimeInterval) { time = Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds) }
        var shown: [Int] = []
        var ended: [ScreenResolutionChange.Outcome] = []
        var said: [String] = []
        func change(_ screens: FakeScreens) -> ScreenResolutionChange {
            at(0)
            shown = []
            ended = []
            said = []
            let change = ScreenResolutionChange(switcher: screens, clock: { time })
            change.onShow = { _, seconds in shown.append(seconds) }
            change.onEnd = { _, outcome in ended.append(outcome) }
            change.report = { said.append($0) }
            return change
        }
        let low = wide[2], fast = wide[3]

        var screens = fakeScreens()
        var c = change(screens)
        check(c.choose(low, on: 5, name: "Ultrawide") && screens.asked == ["5: mode 44 session"] && screens.now[5] == low,
              "choosing a mode applies it for this session only: \(screens.asked.joined(separator: ", "))")
        check(shown == [15] && c.pending?.previous == wide[0] && c.pending?.chosenTitle == "1920 × 1080, 60 Hz"
              && c.pending?.previousTitle == "3440 × 1440, 100 Hz (native)", "and asks, with 15 seconds to go back to 3440 × 1440, 100 Hz (native)")
        at(5.2)
        c.tick()
        check(shown.last == 10 && c.pending != nil, "5.2 s later: 10 seconds left (\(shown.last.map(String.init) ?? "none"))")
        screens.forget()
        c.keep()
        check(screens.asked == ["5: mode 44 saved"] && ended == [.kept] && c.pending == nil && screens.now[5] == low,
              "Keep saves the same mode for good, and that's the end: \(screens.asked.joined(separator: ", "))")
        at(30)
        c.tick()
        check(ended == [.kept] && screens.asked.count == 1, "and the countdown running out later does nothing more")

        screens = fakeScreens()
        c = change(screens)
        c.choose(low, on: 5, name: "Ultrawide")
        screens.forget()
        c.goBack()
        check(screens.asked == ["5: mode 51 session"] && screens.now[5] == wide[0] && ended == [.wentBack],
              "Go Back puts the previous mode back exactly, for the session (nothing was saved): \(screens.asked.joined(separator: ", "))")

        screens = fakeScreens()
        c = change(screens)
        c.choose(low, on: 5, name: "Ultrawide")
        screens.forget()
        at(14.9)
        c.tick()
        check(c.pending != nil && shown.last == 1 && screens.asked.isEmpty, "14.9 s without an answer: still asking, 1 second left")
        at(15)
        c.tick()
        check(screens.asked == ["5: mode 51 session"] && screens.now[5] == wide[0] && ended == [.timedOut] && c.pending == nil,
              "at 15 s it goes back by itself: \(screens.asked.joined(separator: ", "))")

        screens = fakeScreens()
        c = change(screens)
        c.choose(low, on: 5, name: "Ultrawide")
        screens.forget()
        screens.connected = [7]
        at(1)
        c.tick()
        check(c.pending != nil && ended.isEmpty, "a screen gone for a moment is still asked about (it may only be settling into the new mode)")
        screens.connected = [5, 7]
        at(1.5)
        c.tick()
        check(c.pending?.goneSince == nil && ended.isEmpty, "and back within \(Int(ScreenResolutionChange.unplugGrace)) s, the countdown goes on")
        screens.connected = [7]
        at(3)
        c.tick()
        at(5.1)
        c.tick()
        check(ended == [.unplugged] && c.pending == nil && c.awaiting?.key == "24739:4112:0" && screens.asked.isEmpty,
              "unplugged for \(Int(ScreenResolutionChange.unplugGrace)) s: the question ends, nothing is asked of a screen that isn't there")
        screens.connected = [7, 9]
        screens.keys[9] = "24739:4112:0"
        screens.lists[9] = wide
        screens.now[9] = low
        c.screensChanged()
        check(screens.asked == ["9: mode 51 session"] && screens.now[9] == wide[0] && c.awaiting == nil
              && said.last == "resolution: Ultrawide is back in 1920 × 1080, 60 Hz, which wasn't kept: put back 3440 × 1440, 100 Hz (native)",
              "plugged back in (under a new number) still in the mode nobody kept: the previous one is put back, and logged: \(screens.asked.joined(separator: ", "))")

        screens = fakeScreens()
        c = change(screens)
        c.choose(low, on: 5, name: "Ultrawide")
        screens.connected = [7]
        at(3)
        c.tick()
        at(6)
        c.tick()
        screens.forget()
        screens.connected = [5, 7]
        screens.now[5] = wide[0]
        c.screensChanged()
        check(screens.asked.isEmpty && c.awaiting == nil, "back in its saved mode instead (as macOS may bring it back): left alone")

        screens = fakeScreens()
        c = change(screens)
        c.choose(low, on: 5, name: "Ultrawide")
        screens.connected = [7]
        at(14)
        c.tick()
        screens.forget()
        at(15)
        c.tick()
        check(ended == [.unplugged] && screens.asked.isEmpty && c.awaiting != nil, "the countdown running out while it's gone waits for it to come back")
        screens = fakeScreens()
        c = change(screens)
        c.choose(low, on: 5, name: "Ultrawide")
        screens.connected = [7]
        screens.forget()
        c.goBack()
        check(ended == [.unplugged] && screens.asked.isEmpty && c.awaiting != nil, "and so does Go Back answered from another screen while it's gone")

        screens = fakeScreens()
        c = change(screens)
        c.choose(low, on: 5, name: "Ultrawide")
        at(10)
        c.tick()
        screens.forget()
        check(c.choose(fast, on: 5, name: "Ultrawide") && screens.asked == ["5: mode 42 session"] && c.pending?.previous == wide[0]
              && c.pending?.chosen == fast && c.secondsLeft == 15 && shown.last == 15,
              "another mode chosen during the countdown: applied, the countdown starts again, still going back to the first mode")
        screens.forget()
        c.goBack()
        check(screens.asked == ["5: mode 51 session"] && ended == [.wentBack], "so Go Back then returns to the mode from before both")
        c = change(screens)
        c.choose(low, on: 5, name: "Ultrawide")
        screens.forget()
        check(!c.choose(wide[0], on: 5, name: "Ultrawide") && screens.asked == ["5: mode 51 session"] && ended == [.wentBack],
              "choosing the previous mode during the countdown is going back")
        c = change(screens)
        c.choose(low, on: 5, name: "Ultrawide")
        screens.forget()
        check(c.choose(low, on: 5, name: "Ultrawide") && screens.asked.isEmpty && c.secondsLeft == 15,
              "choosing the same new mode again changes nothing")

        screens = fakeScreens()
        c = change(screens)
        c.choose(low, on: 5, name: "Ultrawide")
        screens.forget()
        check(c.choose(side[0], on: 7, name: "4K") && screens.asked == ["5: mode 51 session", "7: mode 1 session"] && ended == [.wentBack]
              && c.pending?.display == 7 && c.pending?.previous == side[1],
              "a mode chosen on another screen during the countdown: the first screen goes back, then the other one is asked about")

        screens = fakeScreens()
        c = change(screens)
        screens.refuses = true
        check(!c.choose(low, on: 5, name: "Ultrawide") && c.pending == nil && shown.isEmpty, "a mode macOS won't switch to: no question")
        screens.refuses = false
        check(!c.choose(wide[0], on: 5, name: "Ultrawide") && screens.asked.count == 1, "nor for the mode already in use")
        screens = fakeScreens()
        c = change(screens)
        c.choose(low, on: 5, name: "Ultrawide")
        screens.refusesToSave = true
        c.keep()
        check(ended == [.keptForSession] && screens.now[5] == low, "Keep that macOS won't save: kept for this session, and said so")
        screens = fakeScreens()
        c = change(screens)
        c.choose(low, on: 5, name: "Ultrawide")
        screens.refuses = true
        c.goBack()
        check(ended == [.failed] && c.pending == nil, "Go Back that macOS refuses: the question ends, and it says the old mode couldn't be put back")
    }

    // MARK: The feature

    static func featureChecks(_ check: Check) {
        let screens = fakeScreens()
        let recorder = Recorder()
        var time = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let feature = ScreenResolution(switcher: screens, clock: { time }, presenter: recorder)
        var said: [String] = []
        feature.change.report = { said.append($0) }
        feature.choose(Pick(display: 5, name: "Ultrawide", mode: wide[2]))
        check(recorder.shown == [ScreenResolutionQuestion(display: 5, name: "Ultrawide", chosen: "1920 × 1080, 60 Hz",
                                                          previous: "3440 × 1440, 100 Hz (native)", secondsLeft: 15)] && feature.isCounting,
              "a choice from the popup asks the question, with the countdown ticking")
        time += 3
        feature.change.tick()
        check(recorder.shown.last?.secondsLeft == 12, "each tick updates it (12 seconds left)")
        recorder.onKeep()
        check(screens.asked.last == "5: mode 44 saved" && recorder.hidden == 1 && !feature.isCounting
              && said == ["resolution: Ultrawide: 1920 × 1080, 60 Hz for this session, kept only if confirmed within 15 s", "resolution: Ultrawide: kept 1920 × 1080, 60 Hz"],
              "its Keep saves the mode and puts the question away; the log says what happened (\(said.count) lines)")
        feature.choose(Pick(display: 5, name: "Ultrawide", mode: wide[4]))
        recorder.onGoBack()
        check(screens.now[5] == wide[2] && recorder.hidden == 2, "its Go Back goes back")
        feature.choose(Pick(display: 5, name: "Ultrawide", mode: wide[4]))
        feature.quitting()
        check(screens.now[5] == wide[2] && recorder.hidden == 3 && !feature.isCounting && said.last == "resolution: Ultrawide: went back to 1920 × 1080, 60 Hz",
              "RubberMAC quitting before an answer goes back too")
        check(!shared.wantsAccess, "a mode change needs no Accessibility")
    }
}
