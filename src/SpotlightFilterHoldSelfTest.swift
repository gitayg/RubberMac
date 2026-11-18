import AppKit
import Carbon.HIToolbox

// Part of --selftest spotlightfilter: the keys held while Spotlight switches to apps. Which events are held, that they
// go to Spotlight in order once the switch is done, that a shortcut, a click, a full queue, the time running out or
// the tap going off lets them go first, that a timer from an earlier hold can't end a later one, how an opening tells
// the hold the switch is done, and what each event costs the keyboard tap. Made-up events and a made-up clock;
// nothing is posted.
extension SpotlightFilterSelfTest {
    static func holdChecks(_ check: Check) {
        decideChecks(check)
        flowChecks(check)
        openingSignalChecks(check)
        costChecks(check)
    }

    private static func decideChecks(_ check: Check) {
        typealias H = SpotlightFilterHold
        func decide(holding: Bool = true, expired: Bool = false, clicked: Bool = false, _ type: CGEventType = .keyDown,
                    flags: UInt64 = 0, key: Int64 = Int64(kVK_ANSI_S), down: Set<Int64> = [], held: Int = 0) -> H.Decision {
            H.decide(holding: holding, expired: expired, clicked: clicked, type: type, flags: flags, keyCode: key, heldDown: down, held: held)
        }
        check(decide(holding: false) == .pass && decide(holding: false, .keyUp) == .pass, "no hold on: every key passes")
        check(decide() == .hold, "a plain key during a hold is held")
        check(decide(flags: Modifiers.shift) == .hold && decide(flags: CGEventFlags.maskAlphaShift.rawValue) == .hold,
              "so is a capital, with ⇧ or Caps Lock")
        check(decide(key: Int64(kVK_Return)) == .hold && decide(key: Int64(kVK_Escape)) == .hold
              && decide(flags: Modifiers.arrowKey, key: Int64(kVK_DownArrow)) == .hold,
              "and ↩, Esc and the arrows, so they stay after the letters typed before them")
        for (flag, name) in [(Modifiers.command, "⌘"), (Modifiers.control, "⌃"), (Modifiers.option, "⌥")] {
            check(decide(flags: flag) == .releaseThenPass, "a key with \(name) lets the held keys go first and passes")
        }
        check(decide(.flagsChanged, flags: Modifiers.shift) == .pass, "a modifier going down or up passes (held keys carry their own)")
        check(decide(.keyUp, down: [Int64(kVK_ANSI_S)]) == .hold, "the key-up of a held key is held")
        check(decide(.keyUp, down: []) == .pass, "the key-up of a key pressed before the hold passes")
        check(decide(expired: true) == .releaseThenPass && decide(expired: true, .keyUp, down: [Int64(kVK_ANSI_S)]) == .releaseThenPass,
              "past the hold's time: let go first, then pass")
        check(decide(clicked: true) == .releaseThenPass, "after a click (focus may be elsewhere now): let go first, then pass")
        check(decide(held: H.maxEvents - 1) == .hold && decide(held: H.maxEvents) == .releaseThenPass,
              "at most \(H.maxEvents) events are held; the next lets them go")
    }

    // A hold with its clock, clicks, timers and replay swapped out.
    final class Rig {
        let hold = SpotlightFilterHold()
        var clock: UInt64 = 1_000_000_000
        var clicks: UInt32 = 7
        var timers: [(at: UInt64, work: () -> Void)] = []
        // Replayed batches as "s↓", "s↑" … and the order of replays and passed keys.
        var batches: [[String]] = []
        var trail: [String] = []

        init() {
            hold.now = { [unowned self] in clock }
            hold.clicks = { [unowned self] in clicks }
            hold.schedule = { [unowned self] delay, work in timers.append((clock + SpotlightFilterHold.nanos(delay), work)) }
            hold.replay = { [unowned self] events in
                let names = events.map(Rig.name)
                batches.append(names)
                trail.append("replay " + names.joined(separator: " "))
            }
        }

        static func name(_ event: CGEvent) -> String {
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let letter = [kVK_ANSI_S: "s", kVK_ANSI_A: "a", kVK_ANSI_F: "f", kVK_Return: "↩"][key] ?? "#\(key)"
            return letter + (event.type == .keyDown ? "↓" : "↑")
        }

        func advance(_ seconds: TimeInterval) {
            clock += SpotlightFilterHold.nanos(seconds)
            let due = timers.filter { $0.at <= clock }.sorted { $0.at < $1.at }
            timers.removeAll { $0.at <= clock }
            due.forEach { $0.work() }
        }

        // nil when held; the event's name when it went on.
        @discardableResult
        func key(_ code: Int, _ down: Bool, _ flags: CGEventFlags = []) -> String? {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
            event.flags = flags
            guard let passed = hold.handle(down ? .keyDown : .keyUp, event) else { return nil }
            trail.append("pass " + Rig.name(passed))
            return Rig.name(passed)
        }

        func type(_ codes: [Int]) -> [String?] { codes.flatMap { [key($0, true), key($0, false)] } }
    }

    private static func flowChecks(_ check: Check) {
        let saf = [kVK_ANSI_S, kVK_ANSI_A, kVK_ANSI_F]
        let inOrder = ["s↓", "s↑", "a↓", "a↑", "f↓", "f↑"]

        var rig = Rig()
        check(rig.type(saf).allSatisfy { $0 != nil } && rig.batches.isEmpty, "with no hold, keys pass straight through")

        // The usual way: held from the bar taking the keyboard, let go a moment after the switch shows done.
        rig = Rig()
        rig.hold.begin()
        let held = rig.type(saf)
        check(held.allSatisfy { $0 == nil } && rig.hold.isHolding, "the bar took the keyboard: s, a, f are held, down and up")
        rig.advance(0.1)
        rig.hold.pressed()
        rig.advance(0.1)
        rig.hold.switched()
        rig.advance(SpotlightFilterHold.afterSwitch - 0.01)
        check(rig.hold.isHolding && rig.batches.isEmpty, "still held just after the switch shows done")
        rig.advance(0.02)
        check(rig.batches == [inOrder] && !rig.hold.isHolding,
              "\(Int(SpotlightFilterHold.afterSwitch * 1000)) ms after it they go to Spotlight, in order: \(rig.batches.first?.joined(separator: " ") ?? "none")")
        check(rig.key(kVK_ANSI_A, true) == "a↓", "and the next key passes as usual")
        check(rig.hold.stats.released == ["switched": 1], "let go because of the switch (\(rig.hold.stats.released))")

        // The ⌘1 went out but the switch isn't seen: let go once the switch should be over.
        rig = Rig()
        rig.hold.begin()
        rig.type([kVK_ANSI_S])
        rig.hold.pressed()
        rig.advance(SpotlightFilterHold.afterPress - 0.01)
        check(rig.hold.isHolding, "with the switch not seen, still held \(Int((SpotlightFilterHold.afterPress - 0.01) * 1000)) ms after the ⌘1")
        rig.advance(0.02)
        check(rig.batches == [["s↓", "s↑"]] && rig.hold.stats.released == ["after ⌘1": 1],
              "let go \(Int(SpotlightFilterHold.afterPress * 1000)) ms after the ⌘1 (\(rig.hold.stats.released))")

        // No ⌘1 at all: the hard limit.
        rig = Rig()
        rig.hold.begin()
        rig.type([kVK_ANSI_S, kVK_ANSI_A])
        rig.advance(SpotlightFilterHold.hardCap - 0.01)
        check(rig.hold.isHolding, "with no ⌘1, still held just before \(Int(SpotlightFilterHold.hardCap * 1000)) ms")
        rig.advance(0.02)
        check(rig.batches == [["s↓", "s↑", "a↓", "a↑"]] && !rig.hold.isHolding && rig.hold.stats.released == ["timeout": 1],
              "at \(Int(SpotlightFilterHold.hardCap * 1000)) ms everything held goes, so a switch that never comes can't swallow typing")

        // Past the time with the timer not run yet: the next key lets the others go first.
        rig = Rig()
        rig.hold.begin()
        rig.type([kVK_ANSI_S])
        rig.clock += SpotlightFilterHold.nanos(SpotlightFilterHold.hardCap + 0.1)
        rig.key(kVK_ANSI_A, true)
        check(rig.trail == ["replay s↓ s↑", "pass a↓"], "a key after the time is up goes after the held ones: \(rig.trail)")

        // A shortcut: the held keys first, then the shortcut, then nothing held.
        rig = Rig()
        rig.hold.begin()
        rig.type([kVK_ANSI_S])
        rig.key(kVK_ANSI_A, true, .maskCommand)
        rig.key(kVK_ANSI_F, true)
        check(rig.trail == ["replay s↓ s↑", "pass a↓", "pass f↓"] && rig.hold.stats.released == ["shortcut": 1],
              "⌘A mid-hold: held keys, then ⌘A, then typing as usual: \(rig.trail)")

        // A click, which may have put another app in front.
        rig = Rig()
        rig.hold.begin()
        rig.type([kVK_ANSI_S])
        rig.clicks += 1
        rig.key(kVK_ANSI_A, true)
        check(rig.trail == ["replay s↓ s↑", "pass a↓"] && rig.hold.stats.released == ["click": 1],
              "a click mid-hold: the keys typed before it go to Spotlight, the ones after pass: \(rig.trail)")

        // A full queue.
        rig = Rig()
        rig.hold.begin()
        for _ in 0..<(SpotlightFilterHold.maxEvents / 2) { rig.type([kVK_ANSI_A]) }
        let overflow = rig.key(kVK_ANSI_S, true)
        check(overflow == "s↓" && rig.batches.map(\.count) == [SpotlightFilterHold.maxEvents] && rig.hold.stats.released == ["full": 1],
              "the \(SpotlightFilterHold.maxEvents + 1)st event lets the \(SpotlightFilterHold.maxEvents) held go first, then passes")

        // Key-ups of keys pressed before the hold, and modifiers.
        rig = Rig()
        rig.hold.begin()
        let upBefore = rig.key(kVK_ANSI_F, false)
        let shift = rig.hold.handle(.flagsChanged, CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: true)!)
        check(upBefore == "f↑" && shift != nil && rig.hold.stats.held == 0, "a key-up from before the hold and a modifier pass")

        // A timer left from an earlier hold.
        rig = Rig()
        rig.hold.begin()
        rig.hold.cancel()
        rig.advance(0.3)
        rig.hold.begin()
        rig.type([kVK_ANSI_S])
        rig.advance(SpotlightFilterHold.hardCap - 0.3 + 0.01)
        check(rig.hold.isHolding && rig.batches.isEmpty, "the first hold's timer, firing during the second, leaves the second alone")
        rig.advance(0.3)
        check(rig.batches == [["s↓", "s↑"]], "which ends at its own time")

        // No switch coming, a new opening, the tap going off.
        rig = Rig()
        rig.hold.begin()
        rig.type([kVK_ANSI_S])
        rig.hold.cancel()
        check(rig.batches == [["s↓", "s↑"]] && rig.hold.stats.released == ["no switch": 1], "no switch coming: let go at once")
        rig = Rig()
        rig.hold.begin()
        rig.type([kVK_ANSI_S])
        rig.hold.begin()
        check(rig.batches == [["s↓", "s↑"]] && rig.hold.isHolding && rig.hold.stats.released == ["superseded": 1],
              "a new opening lets the last one's keys go before holding again")
        rig = Rig()
        rig.hold.begin()
        rig.type([kVK_ANSI_S])
        rig.hold.tapWasDisabled()
        check(rig.batches == [["s↓", "s↑"]] && !rig.hold.isHolding, "the tap switched off for a moment: let go, as unseen keys may have passed")
        check(rig.hold.stats.held == rig.hold.stats.replayed, "everything held is replayed (\(rig.hold.stats.held) held, \(rig.hold.stats.replayed) replayed)")
    }

    private static func openingSignalChecks(_ check: Check) {
        var clock = Date(timeIntervalSince1970: 0)
        var bar = Bar(focusedPid: ui, fieldID: field, placeholder: "Search or Ask")
        let openings = SpotlightFilterOpenings(uiPid: ui, read: { bar }, press: {})
        openings.now = { clock }
        openings.appsTitle = "Applications"
        var settled: [SpotlightFilterOpenings.Step] = []
        var switched = 0
        openings.onSettled = { settled.append($0) }
        openings.onSwitched = { switched += 1 }

        openings.windowCreated()
        check(settled == [.press], "an opening that sends ⌘1 tells the hold so")
        clock += 0.05
        for _ in 1...5 { openings.focusChanged() }
        check(switched == 0, "focus moving while the field still reads \"Search or Ask\" isn't the switch")
        clock += 0.05
        bar.placeholder = "Applications"
        openings.focusChanged()
        openings.focusChanged()
        check(switched == 1, "the empty field's placeholder changing is: told once (\(switched))")

        clock += 5
        bar.placeholder = "Search or Ask"
        openings.windowCreated()
        clock += SpotlightFilterOpenings.armedFor + 0.1
        bar.placeholder = "Applications"
        openings.focusChanged()
        check(switched == 1, "a placeholder change long after the ⌘1 isn't taken for its switch")

        clock += 5
        bar.placeholder = "Applications"
        openings.windowCreated()
        check(settled.last == .alreadyOn, "a bar already showing only apps tells the hold no switch is coming")
    }

    // What the hold adds to each key the tap sees, measured as EventTap runs its handlers (only active ones are
    // called): twelve switched-off handlers stand in for the keyboard tap's others; then the hold is added off and, for
    // comparison, a switched-off handler built like the tap's existing ones (a stored Bool read by isActive) and one
    // whose isActive is a constant. Each is the fastest of five interleaved runs. Reading any switch costs a few ns a
    // key (measured 7-12 ns here); a constant costs nothing, but every real handler has a switch.
    final class ConstantIdle: TapHandler {
        var isActive: Bool { false }
        func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? { event }
    }
    final class StoredIdle: TapHandler {
        var isEnabled = false
        var isActive: Bool { isEnabled }
        func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? { event }
    }

    private static func costChecks(_ check: Check) {
        let keys = SpotlightFilterKeys()
        let others: [TapHandler] = (0..<12).map { _ in ConstantIdle() }
        let withHold = others + [keys]
        let withStored = others + [StoredIdle()]
        let withConstant = others + [ConstantIdle()]
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_S), keyDown: true)!
        let rounds = 400_000
        var passed = 0
        func perEvent(_ handlers: [TapHandler]) -> Double {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0..<rounds {
                var current: CGEvent? = event
                for handler in handlers where handler.isActive {
                    guard let next = current.flatMap({ handler.handle(.keyDown, $0) }) else { current = nil; break }
                    current = next
                }
                if current != nil { passed += 1 }
            }
            return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(rounds)
        }
        keys.isEnabled = false
        var base = Double.infinity, off = Double.infinity, stored = Double.infinity, constant = Double.infinity
        for _ in 0..<5 {
            base = min(base, perEvent(others))
            off = min(off, perEvent(withHold))
            stored = min(stored, perEvent(withStored))
            constant = min(constant, perEvent(withConstant))
        }
        keys.isEnabled = true
        var on = Double.infinity
        for _ in 0..<5 { on = min(on, perEvent(withHold)) }
        keys.hold.now = { 0 }
        keys.hold.schedule = { _, _ in }
        keys.hold.begin()
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for _ in 0..<SpotlightFilterHold.maxEvents { _ = keys.hold.handle(.keyDown, event) }
        let holding = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(SpotlightFilterHold.maxEvents)
        keys.hold.cancel()
        check(passed == rounds * 25, "every made-up key passed when nothing was held")
        let note = String(format: "12 switched-off handlers %.1f ns a key; added: the hold off +%.1f, a handler like the tap's others +%.1f, "
                          + "a constant one +%.1f; the hold on +%.1f; holding %.0f ns a key", base, off - base, stored - base,
                          constant - base, on - base, holding)
        check(off <= stored + 2,
              "switch off: the hold adds no more than one of the tap's other switched-off handlers does, within 2 ns (\(note))")
        check(on - base < 1000, "switch on, no hold: under 1 µs a key")
        check(holding < 20_000, "holding: under 20 µs a key, for at most \(SpotlightFilterHold.maxEvents) keys an opening")
    }
}
