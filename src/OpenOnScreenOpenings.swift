import AppKit

// Which new windows the user just opened: the first ones an app shows right after the user launched it or switched to
// it with a click or a key (a Finder double-click, the Dock, Start, Spotlight), not ones it opens on its own later.
// Pure, on times handed in.
struct OpenOnScreenOpenings {
    // A launch or a switch is the user's when a click or a key came this soon before it.
    static let inputGap: TimeInterval = 2
    // How long a window still counts after a switch, and after a launch, as a big app takes a while to show its first.
    static let afterActivation: TimeInterval = 3
    static let afterLaunch: TimeInterval = 15
    // Once one has appeared, others count only this soon after it: files opened together, not the next one.
    static let siblingGap: TimeInterval = 1

    struct Watch: Equatable {
        var until: Date
        // Windows are numbered in the order they're made, so one numbered above this is new.
        var since: CGWindowID
    }

    private(set) var watches: [pid_t: Watch] = [:]
    // The newest window when the last app switch was seen: one the app made before that isn't the user's new one.
    private(set) var newestAtLastSwitch: CGWindowID

    init(newest: CGWindowID = 0) {
        newestAtLastSwitch = newest
    }

    // All of a just-launched app's windows are new.
    mutating func launched(_ pid: pid_t, at launchDate: Date, now: Date, lastInput: Date) -> Watch? {
        guard lastInput >= launchDate.addingTimeInterval(-Self.inputGap) else { return nil }
        return extend(pid, until: now.addingTimeInterval(Self.afterLaunch), since: 0)
    }

    // Counts every switch, the user's or not, for the next one's `since`.
    mutating func activated(_ pid: pid_t, now: Date, lastInput: Date, newest: CGWindowID) -> Watch? {
        let since = newestAtLastSwitch
        newestAtLastSwitch = newest
        guard now.timeIntervalSince(lastInput) <= Self.inputGap else { return nil }
        return extend(pid, until: now.addingTimeInterval(Self.afterActivation), since: since)
    }

    // Whether a window seen now is one the user just opened.
    mutating func appeared(_ pid: pid_t, window: CGWindowID, at now: Date) -> Bool {
        guard var watch = watches[pid], now <= watch.until, window > watch.since else { return false }
        watch.until = min(watch.until, now.addingTimeInterval(Self.siblingGap))
        watches[pid] = watch
        return true
    }

    mutating func ended(_ pid: pid_t) {
        watches[pid] = nil
    }

    // Drops the watches that are over, and says whose they were.
    mutating func expire(_ now: Date) -> [pid_t] {
        let over = watches.filter { $0.value.until < now }.map(\.key)
        over.forEach { watches[$0] = nil }
        return over
    }

    private mutating func extend(_ pid: pid_t, until: Date, since: CGWindowID) -> Watch {
        var watch = watches[pid] ?? Watch(until: until, since: since)
        watch.until = max(watch.until, until)
        watch.since = min(watch.since, since)
        watches[pid] = watch
        return watch
    }

    // MARK: This Mac

    // The last click or key press, anywhere.
    static func lastInput() -> Date {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        let seconds = types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.reduce(.infinity, min)
        return Date(timeIntervalSinceNow: -seconds)
    }

    static func newestWindow() -> CGWindowID {
        NSWindow.windowNumbers(options: [.allApplications, .allSpaces])?.map(\.uint32Value).max() ?? 0
    }
}
