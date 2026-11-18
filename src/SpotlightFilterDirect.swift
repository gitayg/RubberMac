import AppKit
import Carbon.HIToolbox

// --selftest spotlightfilter-direct: the hold with real Spotlight, for when the keyboard tap can't see keys (Secure
// Input hides them from every tap, and a tap never sees its own process's). The feature runs here; s, a, f are handed
// to its hold from a thread of their own, as the keyboard tap's thread would, the first 40, 60, 80 or 100 ms after the
// shortcut, 60 ms apart, three times each. A key the hold lets pass is posted as a typed key, only while Spotlight has
// the keyboard; a held one reaches Spotlight only through the hold's own replay. The field is read once things settle.
// Gated like the probe.
enum SpotlightFilterDirect {
    static func report() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else { return "skipped: the screen is locked" }
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) { return "skipped: a full-screen app's desktop is showing" }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else { return "skipped: the Mac was in use \(Int(idle)) s ago" }
        guard SpotlightKeys.spotlightWindows().isEmpty else { return "skipped: Spotlight is already open" }
        guard let shortcut = Spotlight.searchShortcut() else { return "skipped: Spotlight's shortcut is off" }
        guard let ui = NSRunningApplication.runningApplications(withBundleIdentifier: SpotlightFilter.uiBundleID).first else { return "skipped: no \(SpotlightFilter.uiBundleID)" }
        let pid = ui.processIdentifier
        func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: s)) }
        func waitFor(_ s: TimeInterval, _ c: () -> Bool) -> Bool {
            let start = Date()
            while -start.timeIntervalSinceNow < s { if c() { return true }; pump(0.002) }
            return c()
        }
        // Asks the system, not Spotlight, so it never waits on Spotlight; safe from any thread.
        func spotlightHasKeyboard() -> Bool {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
                  let value else { return false }
            var focused: pid_t = 0
            return AXUIElementGetPid(value as! AXUIElement, &focused) == .success && focused == pid
        }
        let appElement = AX.app(pid)
        AXUIElementSetMessagingTimeout(appElement, 1)
        func value() -> String {
            var e: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &e) == .success, let e else { return "?" }
            return AX.string(e as! AXUIElement, kAXValueAttribute) ?? "?"
        }
        func back() -> Bool {
            func find(_ element: AXUIElement, _ depth: Int) -> Bool {
                if AX.string(element, kAXRoleAttribute) == kAXButtonRole, AX.string(element, kAXDescriptionAttribute) == "Back" { return true }
                guard depth < 4 else { return false }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success else { return false }
                return ((children as? [AXUIElement]) ?? []).prefix(8).contains { find($0, depth + 1) }
            }
            return AX.windows(of: pid).contains { find($0, 0) }
        }
        let source = CGEventSource(stateID: .hidSystemState)
        func escape() {
            for down in [true, false] {
                let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: down)
                ev?.flags = []
                ev?.post(tap: .cghidEventTap)
            }
        }
        func close() {
            for _ in 1...4 where spotlightHasKeyboard() {
                escape()
                _ = waitFor(0.8) { !spotlightHasKeyboard() }
            }
            _ = waitFor(3) { SpotlightKeys.spotlightWindows().isEmpty }
            pump(0.6)
        }

        let feature = SpotlightFilter()
        feature.isOn = { true }
        feature.start()
        guard feature.watcher != nil else { return "FAIL couldn't watch" }
        let hold = feature.keys.hold
        var out: [String] = []
        var tally: [Int: (kept: Int, trials: Int)] = [:]
        for delay in [40, 60, 80, 100] {
            for _ in 1...3 {
                let before = hold.stats
                let t0 = Date()
                Spotlight.openSearch(shortcut)
                // The typing, on a thread of its own as the keyboard tap's is; each key's fate is noted as it goes.
                let done = DispatchSemaphore(value: 0)
                var fates: [String] = []
                let typist = Thread {
                    for (i, code) in [kVK_ANSI_S, kVK_ANSI_A, kVK_ANSI_F].enumerated() {
                        Thread.sleep(until: t0.addingTimeInterval(Double(delay + 60 * i) / 1000))
                        let at = Int(-t0.timeIntervalSinceNow * 1000)
                        var fate = "\(at) "
                        for down in [true, false] {
                            if !down { Thread.sleep(forTimeInterval: 0.03) }
                            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
                            event.flags = []
                            if let passed = hold.handle(down ? .keyDown : .keyUp, event) {
                                if spotlightHasKeyboard() { passed.post(tap: .cghidEventTap); fate += down ? "typed" : "" } else { fate += down ? "not typed" : "" }
                            } else {
                                fate += down ? "held" : ""
                            }
                        }
                        fates.append(fate)
                    }
                    done.signal()
                }
                typist.start()
                while done.wait(timeout: .now()) == .timedOut { pump(0.002) }
                _ = waitFor(1) { back() }
                pump(0.7)
                let v = value()
                let full = v.count == 3
                let after = hold.stats
                let reasons = after.released.filter { (before.released[$0.key] ?? 0) < $0.value }.map(\.key).sorted().joined(separator: ",")
                let entry = tally[delay] ?? (0, 0)
                tally[delay] = (entry.kept + (full ? 1 : 0), entry.trials + 1)
                out.append("first key \(delay) ms: keys \(fates.joined(separator: ", ")); held \(after.held - before.held), replayed "
                           + "\(after.replayed - before.replayed) (\(reasons.isEmpty ? "-" : reasons)); apps only \(back()); field \"\(v)\" \(full ? "all kept" : "LOST")")
                close()
            }
        }
        feature.isOn = { false }
        feature.apply()
        out.append("Secure Input \(IsSecureEventInputEnabled() ? "on" : "off") (the keyboard tap isn't used here)")
        out.append("tally: " + tally.sorted { $0.key < $1.key }.map { "\($0.key) ms \($0.value.kept)/\($0.value.trials) all kept" }.joined(separator: ", "))
        if !SpotlightKeys.spotlightWindows().isEmpty { out.append("note: Spotlight was left open") }
        return out.joined(separator: "\n")
    }
}
