import AppKit
import Synchronization

// Keys typed into Spotlight while it switches to apps. Spotlight wipes a letter that reaches it mid-switch (measured:
// every first letter that landed with the ⌘1 was lost), so from the moment its bar takes the keyboard until the
// switch is done the keyboard tap holds plain keys here, and they're handed to Spotlight afterwards, in order. A key
// with ⌘, ⌃ or ⌥, a click, a full queue or the time running out lets everything go first, so nothing is held for
// long, nothing meant for another app is held at all, and a switch that never comes can't swallow typing. The tap's
// thread decides; the main thread begins and ends a hold; the state is shared under one lock.
final class SpotlightFilterHold: @unchecked Sendable {
    enum Decision: Equatable {
        case pass, hold, releaseThenPass
    }

    // From the bar taking the keyboard: Spotlight is answering by 70-115 ms and done switching 105-160 ms after the
    // ⌘1 (measured), so these leave room to spare.
    static let hardCap: TimeInterval = 0.6
    static let afterPress: TimeInterval = 0.35
    static let afterSwitch: TimeInterval = 0.05
    static let maxEvents = 40

    // What happens to one event while a hold may be on. Modifier changes pass (the held keys carry their own flags);
    // a key-up is held only if its key-down was.
    static func decide(holding: Bool, expired: Bool, clicked: Bool, type: CGEventType, flags: UInt64, keyCode: Int64,
                       heldDown: Set<Int64>, held: Int) -> Decision {
        guard holding, type == .keyDown || type == .keyUp else { return .pass }
        if expired || clicked { return .releaseThenPass }
        if type == .keyUp { return heldDown.contains(keyCode) ? .hold : .pass }
        if flags & (Modifiers.command | Modifiers.control | Modifiers.option) != 0 { return .releaseThenPass }
        return held >= maxEvents ? .releaseThenPass : .hold
    }

    struct Stats: Equatable {
        var holds = 0
        var held = 0
        var replayed = 0
        var released: [String: Int] = [:]
    }

    private struct State {
        var holding = false
        var started: UInt64 = 0
        var until: UInt64 = 0
        var clicks: UInt32 = 0
        var events: [CGEvent] = []
        var down: Set<Int64> = []
        var stats = Stats()
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "spotlight filter hold")

    // The system's side, swapped out by the self-test. replay is called with the lock held, so keys arriving
    // meanwhile wait and come after the replayed ones.
    var now: () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    var clicks: () -> UInt32 = { CommandTap.Counters.now().clicks }
    var replay: ([CGEvent]) -> Void = { _ in }
    var schedule: (TimeInterval, @escaping () -> Void) -> Void
    var onRelease: (_ count: Int, _ ms: Int, _ reason: String) -> Void = { _, _, _ in }

    init() {
        let queue = self.queue
        schedule = { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    var isHolding: Bool { state.withLock { $0.holding } }
    var stats: Stats { state.withLock { $0.stats } }

    // The bar took the keyboard.
    func begin() {
        let time = now()
        let clicks = clicks()
        state.withLock { s in
            if s.holding { release(&s, "superseded") }
            s.holding = true
            s.started = time
            s.until = time + Self.nanos(Self.hardCap)
            s.clicks = clicks
            s.events = []
            s.down = []
            s.stats.holds += 1
        }
        releaseLater(after: Self.hardCap, "timeout")
    }

    // The ⌘1 went out: the switch should be over well within afterPress.
    func pressed() { shorten(to: Self.afterPress, "after ⌘1") }

    // Spotlight showed the switch done: a moment more for its new field, then let go.
    func switched() { shorten(to: Self.afterSwitch, "switched") }

    // No switch is coming (the bar already shows only apps, or it wasn't the bar).
    func cancel() {
        state.withLock { s in if s.holding { release(&s, "no switch") } }
    }

    // On the keyboard tap's thread.
    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        state.withLock { s -> CGEvent? in
            guard s.holding else { return event }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let decision = Self.decide(holding: true, expired: now() >= s.until, clicked: clicks() != s.clicks, type: type,
                                       flags: event.flags.rawValue, keyCode: keyCode, heldDown: s.down, held: s.events.count)
            switch decision {
            case .pass:
                return event
            case .hold:
                s.events.append(event.copy() ?? event)
                if type == .keyDown { s.down.insert(keyCode) }
                s.stats.held += 1
                return nil
            case .releaseThenPass:
                let reason = now() >= s.until ? "timeout" : clicks() != s.clicks ? "click" : type == .keyDown
                    && event.flags.rawValue & (Modifiers.command | Modifiers.control | Modifiers.option) != 0 ? "shortcut" : "full"
                release(&s, reason)
                return event
            }
        }
    }

    // The system switched the tap off for a moment: keys may have gone past unseen, so order can't be kept by holding.
    func tapWasDisabled() {
        state.withLock { s in if s.holding { release(&s, "tap off") } }
    }

    private func shorten(to seconds: TimeInterval, _ reason: String) {
        let time = now()
        let holding = state.withLock { s -> Bool in
            guard s.holding else { return false }
            s.until = min(s.until, time + Self.nanos(seconds))
            return true
        }
        if holding { releaseLater(after: seconds, reason) }
    }

    // Lets go only once the hold's time is up, so a timer left from an earlier hold, firing during a later one,
    // does nothing until the later one's own time. A timer can't fire early, but the clock it's read by may be a hair
    // behind the one it was set by.
    private func releaseLater(after seconds: TimeInterval, _ reason: String) {
        schedule(seconds) { [weak self] in
            self?.state.withLock { s in
                if s.holding, (self?.now() ?? 0) + 2_000_000 >= s.until { self?.release(&s, reason) }
            }
        }
    }

    private func release(_ s: inout State, _ reason: String) {
        let events = s.events
        let ms = Int((now() &- s.started) / 1_000_000)
        s.holding = false
        s.events = []
        s.down = []
        s.stats.replayed += events.count
        s.stats.released[reason, default: 0] += 1
        if !events.isEmpty { replay(events) }
        onRelease(events.count, ms, reason)
    }

    static func nanos(_ seconds: TimeInterval) -> UInt64 { UInt64(seconds * 1e9) }
}

// The hold's place in the keyboard tap: on only while the switch is. The tap asks isActive of every key, from its own
// thread: an atomic read costs what any switched-off handler's check does, where a plain stored property adds a
// runtime access check (measured, about 6 ns a key).
final class SpotlightFilterKeys: TapHandler {
    let hold = SpotlightFilterHold()
    // From the setting at once: the keyboard tap is first started before the features are.
    private let enabled = Atomic<Bool>(Settings.spotlightAppsOnlyEnabled)
    var isEnabled: Bool {
        get { enabled.load(ordering: .relaxed) }
        set { enabled.store(newValue, ordering: .relaxed) }
    }
    var isActive: Bool { enabled.load(ordering: .relaxed) }

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? { hold.handle(type, event) }
    func tapWasDisabled() { hold.tapWasDisabled() }
}
