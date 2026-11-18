import AppKit
import Carbon

// --selftest spotlightfilter-host <seconds> <stop file>: the feature on in this process with a keyboard tap of its
// own, the hold last in it as in the app, for the typing harness in another process to type at (a tap never sees keys
// posted by its own process). Prints what the tap saw and what was held, replayed and why, then exits when the stop
// file appears or the time is up. Holds only what the real feature would; it never posts anything but the ⌘1 and the
// held keys, both to Spotlight's process.
enum SpotlightFilterHost {
    // Counts the key-downs the tap sees ahead of the hold, never which keys.
    final class Seen: TapHandler {
        var keyDowns = 0
        var isActive: Bool { true }
        func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
            if type == .keyDown { keyDowns += 1 }
            return event
        }
    }

    static func run(seconds: TimeInterval, stopFile: String?) -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: SpotlightFilter.uiBundleID).first != nil else {
            return "skipped: Spotlight's search bar (\(SpotlightFilter.uiBundleID)) isn't running"
        }
        let feature = SpotlightFilter()
        feature.isOn = { true }
        feature.start()
        guard feature.watcher != nil else { return "FAIL couldn't watch Spotlight's search bar" }
        let seen = Seen()
        let tap = EventTap(name: "spotlight hold test", types: [.keyDown, .keyUp, .flagsChanged], location: .cghidEventTap,
                           ownThread: true, handlers: [seen, feature.keys])
        tap.update()
        guard tap.isRunning else { return "FAIL the keyboard tap didn't start" }
        var lines = ["host ready: tap on, Secure Input \(IsSecureEventInputEnabled() ? "ON (keys are hidden from taps)" : "off")"]
        if let stopFile { FileManager.default.createFile(atPath: stopFile + ".ready", contents: nil) }
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            if let stopFile, FileManager.default.fileExists(atPath: stopFile) { break }
        }
        let stats = feature.keys.hold.stats
        let presses = feature.watcher?.openings.presses ?? -1
        let received = feature.watcher?.received.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ") ?? "-"
        feature.isOn = { false }
        feature.apply()
        lines.append("key-downs the tap saw: \(seen.keyDowns); ⌘1 sent: \(presses); holds: \(stats.holds); events held: \(stats.held), "
                     + "replayed: \(stats.replayed); let go: " + stats.released.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))
        lines.append("Spotlight's notices: \(received)")
        lines.append(stats.held == stats.replayed ? "ok   every held event was replayed" : "FAIL held \(stats.held), replayed \(stats.replayed)")
        return lines.joined(separator: "\n")
    }
}
