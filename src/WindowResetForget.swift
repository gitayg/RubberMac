import AppKit

// Making one app forget where its windows were and how big, as the fix people post for Terminal does it
// (defaults delete com.apple.iCal "NSWindow Frame iCal", with the app quit): quit it, delete its saved frames, move the
// windows macOS kept for it to the Trash, and open it again. Nothing else of it is touched.
enum WindowResetForget {
    enum Trashed: Equatable {
        case moved(URL), absent, failed
    }

    enum Quit: Equatable {
        case quit
        // Still open after the wait: it may be asking about unsaved work.
        case stillOpen
        // Asking an app to quit is an Apple event, which macOS lets RubberMAC send only once the user has said so.
        case notAllowed
    }

    // Each step, so the self-test can stand in for the app, its preferences and the Trash.
    struct Steps {
        var running: (String) -> [pid_t]
        // Asks each copy to quit, then waits.
        var quit: ([pid_t]) -> Quit
        // Every key a preferences domain holds now; nil when it can't be read.
        var keys: (String) -> [String]?
        var delete: (_ domain: String, _ key: String) -> Bool
        var trash: (URL) -> Trashed
        var reopen: (URL) -> Void
    }

    struct Outcome: Equatable {
        // Not .quit when it stopped before forgetting anything.
        var quit = Quit.quit
        var removed = 0
        // Frames that wouldn't delete, or a domain that couldn't be read.
        var failed = 0
        var trashed = Trashed.absent
        var reopened = false
    }

    // Off the main thread: it waits for the app to quit.
    static func run(_ app: WindowResetSavedFrames.App, _ steps: Steps) -> Outcome {
        var outcome = Outcome()
        let open = steps.running(app.bundleID)
        if !open.isEmpty {
            outcome.quit = steps.quit(open)
            guard outcome.quit == .quit else { return outcome }
        }
        // Read again now it's closed: an app saves its window frames on its way out.
        for domain in [app.bundleID] + [app.container?.path].compactMap({ $0 }) {
            guard let keys = steps.keys(domain) else {
                outcome.failed += 1
                continue
            }
            for key in keys where WindowResetSavedFrames.isFrameKey(key) {
                if steps.delete(domain, key) { outcome.removed += 1 } else { outcome.failed += 1 }
            }
        }
        outcome.trashed = steps.trash(app.savedState)
        if !open.isEmpty {
            steps.reopen(app.url)
            outcome.reopened = true
        }
        return outcome
    }

    // Asked before anything happens, naming the app.
    static func confirmation(for app: WindowResetSavedFrames.App, isOpen: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.icon = NSWorkspace.shared.icon(forFile: app.url.path)
        if isOpen {
            alert.messageText = "Quit \(app.name), forget where its windows were and how big, and open it again?"
            alert.informativeText = "The windows it has open won't come back: it opens with new ones, at their usual size and place. "
                + "Its other settings stay as they are."
            alert.addButton(withTitle: "Quit and Forget")
        } else {
            alert.messageText = "Forget where \(app.name)'s windows were and how big?"
            alert.informativeText = "Next time it opens, its windows come up at their usual size and place, and the ones it had open "
                + "don't come back. Its other settings stay as they are."
            alert.addButton(withTitle: "Forget")
        }
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}

extension WindowResetForget.Outcome {
    func note(_ name: String) -> String {
        switch quit {
        case .stillOpen: return "\(name) didn't quit, so nothing was forgotten; it may be asking about unsaved work"
        case .notAllowed:
            return "macOS didn't let RubberMAC quit \(name), so nothing was forgotten; allow it in Privacy & Security › Automation"
        case .quit: break
        }
        if failed > 0 || trashed == .failed { return "Forgot some of \(name)'s window sizes; the rest couldn't be removed" }
        if removed == 0, trashed == .absent { return "\(name) had no window sizes left to forget" }
        return "Forgot \(name)'s window sizes" + (reopened ? " and opened it again" : "")
    }

    func logLine(_ name: String) -> String {
        switch quit {
        case .stillOpen: return "window reset: \(name) didn't quit; nothing forgotten"
        case .notAllowed: return "window reset: not allowed to quit \(name); nothing forgotten"
        case .quit: break
        }
        var line = "window reset: \(name) forgot \(removed) window frame\(removed == 1 ? "" : "s")"
        if failed > 0 { line += ", \(failed) couldn't be removed" }
        switch trashed {
        case .moved: line += ", its saved windows went to the Trash"
        case .failed: line += ", its saved windows couldn't go to the Trash"
        case .absent: break
        }
        return line + (reopened ? ", opened again" : "")
    }
}

extension WindowResetForget.Steps {
    // quitWait: how long an app has to quit before it counts as still open.
    static func real(quitWait: TimeInterval = 15) -> Self {
        Self(running: { NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier) },
             quit: { pids in
                 // The question first, which waits for the answer: once the user has said yes the quit goes straight
                 // through, rather than the wait below running out while the question is still up.
                 for pid in pids where mayQuit(pid, ask: true) == OSStatus(errAEEventNotPermitted) { return .notAllowed }
                 // terminate(), never forceTerminate(): an app with unsaved work asks first, and its answer stands.
                 let asked = pids.compactMap(NSRunningApplication.init(processIdentifier:)).map { $0.terminate() }
                 guard !asked.contains(false) else { return .stillOpen }
                 let until = Date(timeIntervalSinceNow: quitWait)
                 while pids.contains(where: isAlive), Date() < until { Thread.sleep(forTimeInterval: 0.1) }
                 return pids.contains(where: isAlive) ? .stillOpen : .quit
             },
             // Through the preferences daemon, as defaults goes, so it's what the app last wrote even if not yet on disk,
             // and the daemon's copy changes with the file.
             keys: { domain in
                 guard let data = defaults(["export", domain, "-"]),
                       let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
                 return dictionary.keys.sorted()
             },
             delete: { domain, key in defaults(["delete", domain, key]) != nil },
             trash: { url in
                 guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
                 var moved: NSURL?
                 guard (try? FileManager.default.trashItem(at: url, resultingItemURL: &moved)) != nil else { return .failed }
                 return .moved(moved as URL? ?? url)
             },
             reopen: { url in
                 DispatchQueue.main.async { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
             })
    }

    // Whether RubberMAC may send this app the quit event: noErr, errAEEventNotPermitted (the user said no), or
    // errAEEventWouldRequireUserConsent when not asking and not asked yet.
    static func mayQuit(_ pid: pid_t, ask: Bool) -> OSStatus {
        AEDeterminePermissionToAutomateTarget(NSAppleEventDescriptor(processIdentifier: pid).aeDesc, AEEventClass(kCoreEventClass),
                                              AEEventID(kAEQuitApplication), ask)
    }

    // Not our child, so it's reaped as it ends.
    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // What defaults printed, when it exits 0.
    static func defaults(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
