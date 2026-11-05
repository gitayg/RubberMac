import AppKit
import Carbon.HIToolbox

// --selftest tap: does a busy main thread hold up keys? A probe tap posts an F18 of its own (and swallows it, so
// no app sees it) while the main thread sleeps 0.4 s, first with the tap on the main thread, then on its own one.
extension EventTap {
    static func selfTestReport() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }

        func waited(ownThread: Bool) -> TimeInterval? {
            let probe = Probe()
            let tap = EventTap(name: "probe", types: [.keyDown, .keyUp], location: .cghidEventTap, ownThread: ownThread,
                               handlers: [probe])
            tap.update()
            guard tap.isRunning else { return nil }
            defer { probe.isActive = false; tap.update() }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { probe.post() }
            Thread.sleep(forTimeInterval: 0.4)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            return probe.waited
        }
        let onMain = waited(ownThread: false)
        let onOwn = waited(ownThread: true)
        func ms(_ t: TimeInterval?) -> String { t.map { "\(Int($0 * 1000)) ms" } ?? "never arrived" }
        check((onMain ?? 0) > 0.25, "with the tap on the main thread, a key waits for it (\(ms(onMain)))")
        check(onOwn.map { $0 < 0.05 } == true, "with the tap on its own thread, it doesn't (\(ms(onOwn)))")
        lines.append(failures == 0 ? "PASS" : "FAIL: \(failures) failed")
        return lines.joined(separator: "\n")
    }
}

private final class Probe: TapHandler {
    private static let marker: Int64 = 0x5354_5441_5050  // "STTAPP"
    var isActive = true
    private var arrival: TimeInterval?
    var waited: TimeInterval? { lock.withLock { arrival } }
    private var posted = DispatchTime.now()
    private let lock = NSLock()

    func post() {
        lock.withLock { posted = DispatchTime.now() }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_F18), keyDown: down)
            event?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event?.post(tap: .cghidEventTap)
        }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard event.getIntegerValueField(.eventSourceUserData) == Self.marker else { return event }
        if type == .keyDown {
            let now = DispatchTime.now()
            lock.withLock { arrival = Double(now.uptimeNanoseconds - posted.uptimeNanoseconds) / 1e9 }
        }
        return nil
    }
}
