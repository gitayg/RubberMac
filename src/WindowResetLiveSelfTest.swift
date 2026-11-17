import AppKit

// --selftest windowreset-live [folder] [ask]: the real thing, on things it makes. Builds a scratch app (WindowReset Test)
// into the folder with one window too big for the screen, one mostly off it and one that's fine, and brings the first
// two back through Accessibility as the button does, leaving the third. Moves a window of its own to another desktop to
// see what Bring Back makes of windows there, and counts, moving none, the windows of yours a press would move now.
// Then forgets the scratch app's window sizes for real: deleting its frames with defaults, putting its saved windows in
// the Trash and opening it again, at its usual size. Quitting it first needs the user's yes for Automation: once that's
// given (ask puts the question up) the flow quits it itself, once while it refuses, then for real; until then the test
// closes it. Cleans up all it made, even after a failure. Puts windows on the screen and opens an app, so it waits for
// an idle, ordinary desktop.
enum WindowResetLiveSelfTest {
    static func report() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return "skipped: the screen is locked"
        }
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) {
            return "skipped: a full-screen app's desktop is showing; switch to an ordinary desktop and run again"
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else { return "skipped: the Mac was in use \(Int(idle)) s ago; run it after 20 s without typing or the mouse" }

        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let run = Run()
        run.start()
        run.cleanUp()
        return (run.lines + [run.failures == 0 ? "PASS" : "FAIL: \(run.failures) failed"]).joined(separator: "\n")
    }

    private final class Run {
        var lines: [String] = []
        var failures = 0
        let fm = FileManager.default
        let id = WindowResetScratchApp.bundleID
        let folder: URL
        let app: URL
        let control: URL
        let savedState: URL
        let previous = NSWorkspace.shared.frontmostApplication
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let stored: NSDictionary?
        var trashed: URL?
        var ownWindow: NSWindow?

        init() {
            let args = CommandLine.arguments
            let base = args.firstIndex(of: "windowreset-live").flatMap { $0 + 1 < args.count && args[$0 + 1] != "ask" ? URL(fileURLWithPath: args[$0 + 1]) : nil }
                ?? FileManager.default.temporaryDirectory
            folder = base.appendingPathComponent("windowreset-live-\(UUID().uuidString.prefix(6))")
            app = folder.appendingPathComponent("\(WindowResetScratchApp.name).app")
            control = WindowResetScratchApp.control(app)
            savedState = WindowResetSavedFrames.realPlaces().savedState.appendingPathComponent("\(WindowResetScratchApp.bundleID).savedState")
            stored = Self.settings(domain)
        }

        // Less the focus order, which the running RubberMAC writes whenever a window comes forward.
        static func settings(_ domain: String) -> NSDictionary? {
            UserDefaults.standard.persistentDomain(forName: domain).map { $0.filter { $0.key != "focusHistory" } as NSDictionary }
        }

        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }

        func note(_ text: String) { lines.append("     \(text)") }

        func pump(_ seconds: TimeInterval) {
            let until = Date(timeIntervalSinceNow: seconds)
            repeat {
                while let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            } while Date() < until
        }

        // Milliseconds until the condition held, nil if it didn't in time.
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Int? {
            let start = Date()
            while -start.timeIntervalSinceNow < seconds {
                if condition() { return Int(-start.timeIntervalSinceNow * 1000) }
                pump(0.05)
            }
            return condition() ? Int(seconds * 1000) : nil
        }

        // Accessibility calls into this process, and the forget flow's waits, need the main thread free.
        func offMain<T>(_ body: @escaping () -> T) -> T {
            nonisolated(unsafe) var result: T?
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { result = body(); done.signal() }
            while done.wait(timeout: .now()) == .timedOut { pump(0.01) }
            return result!
        }

        func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

        var scratchApps: [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: id) }

        func scratchWindows(_ pid: pid_t) -> [WindowResetMover.Window] {
            WindowResetMover.ordinaryWindows(of: [WindowResetMover.App(pid: pid, name: WindowResetScratchApp.name)])
                .sorted { title($0) < title($1) }
        }

        // The scratch app's own window names, which the report may show; never a window of yours.
        func title(_ window: WindowResetMover.Window) -> String {
            AX.string(window.element, kAXTitleAttribute) ?? ""
        }

        func window(_ name: String, in windows: [WindowResetMover.Window]) -> WindowResetMover.Window? {
            windows.first { title($0) == "Scratch \(name)" }
        }

        func text(_ rect: CGRect?) -> String {
            rect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "none"
        }

        func keys() -> [String] { WindowResetForget.Steps.real().keys(id) ?? [] }

        func start() {
            // What a run cut short left behind.
            _ = WindowResetForget.Steps.defaults(["delete", id])
            try? fm.removeItem(at: savedState)

            let began = Date()
            if let problem = WindowResetScratchApp.build(app) { return check(false, "build the scratch app: \(problem)") }
            check(true, "built the scratch app with swiftc in \(Int(-began.timeIntervalSinceNow)) s")

            let screens = WindowSnapper.screenAreas()
            let primary = screens[0]
            let rightmost = screens.max { $0.frame.maxX < $1.frame.maxX }!
            let placed = [
                CGRect(x: primary.visible.minX + 60, y: primary.visible.minY + 10, width: primary.visible.width + 300, height: primary.visible.height + 200),
                CGRect(x: rightmost.frame.maxX - 100, y: rightmost.visible.minY + 100, width: 600, height: 400),
                CGRect(x: primary.visible.minX + 100, y: primary.visible.minY + 100, width: 500, height: 300),
            ]
            try? placed.map { "\($0.minX) \($0.minY) \($0.width) \($0.height)" }.joined(separator: "\n")
                .write(to: control.appendingPathComponent("frames"), atomically: true, encoding: .utf8)
            guard let first = launch() else { return }
            var windows: [WindowResetMover.Window] = []
            // Slow to answer while the Mac is busy (one of three windows after 10 s once, with builds running).
            let up = waitFor(20) { windows = scratchWindows(first.processIdentifier); return windows.count == 3 }
            try? fm.removeItem(at: control.appendingPathComponent("frames"))
            guard up != nil else {
                return check(false, "its three windows show through Accessibility (\(windows.count) do)")
            }
            bringBackChecks(windows, placed: placed, screens: screens)
            otherDesktopChecks()
            dryRun(screens, scratch: first.processIdentifier)
            forgetChecks(first)
        }

        func launch() -> NSRunningApplication? {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            var launched: NSRunningApplication?
            var failure: Error?
            NSWorkspace.shared.openApplication(at: app, configuration: config) { app, error in
                DispatchQueue.main.async { launched = app; failure = error }
            }
            guard waitFor(15, { launched != nil || failure != nil }) != nil, let launched else {
                check(false, "open the scratch app (\(failure.map { "error \(($0 as NSError).code)" } ?? "no answer in 15 s"))")
                return nil
            }
            return launched
        }

        // MARK: Bring Back

        func bringBackChecks(_ windows: [WindowResetMover.Window], placed: [CGRect], screens: [ScreenArea]) {
            let frames = WindowResetScratchApp.windowNames.map { window($0, in: windows)?.frame }
            check(zip(frames, placed).allSatisfy { got, wanted in got.map { SnapGeometry.isClose($0, wanted) } == true },
                  "the scratch windows came up where they were put: \(frames.map(text).joined(separator: " | "))")
            let verdicts = frames.map { $0.flatMap { WindowResetGeometry.problem($0, screens: screens) } }
            check(verdicts == [.tooBig, .offScreen, nil], "one is too big for the screen, one mostly off it, one fine: "
                  + verdicts.map { $0.map { "\($0)" } ?? "fine" }.joined(separator: ", "))

            let outcome = WindowResetMover.bringBack(windows, screens: screens, apply: true)
            let after = WindowResetScratchApp.windowNames.map { name in window(name, in: windows).flatMap { AX.frame(of: $0.element) } }
            check(outcome.checked == 3 && outcome.lost.count == 2 && outcome.moved.count == 2 && outcome.stuck.isEmpty,
                  "through Accessibility, as the button does: \(outcome.note)")
            check(after[0].map { WindowResetGeometry.problem($0, screens: screens) == nil } == true,
                  "the too-big one now fits its screen: \(text(after[0]))")
            check(after[1].map { WindowResetGeometry.problem($0, screens: screens) == nil && $0.size == frames[1]?.size } == true,
                  "the one off the screen is back on it, the same size: \(text(frames[1])) → \(text(after[1]))")
            check(after[2] != nil && after[2] == frames[2], "the fine one wasn't touched: \(text(after[2]))")
            note("the log would say: \(outcome.logLine)")
        }

        // A window of the test's own, moved to another desktop: does Accessibility list it, and does Bring Back look at it?
        func otherDesktopChecks() {
            guard let spaces = SpaceWindows.spaces(),
                  let other = spaces.user.subtracting(spaces.current).subtracting(spaces.fullScreen).sorted().first else {
                return note("no second desktop: what happens to windows on other desktops wasn't measured")
            }
            let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 420, height: 300), styleMask: WindowResetScratchApp.style,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            ownWindow = window
            pump(0.5)
            let number = CGWindowID(window.windowNumber)
            let me = WindowResetMover.App(pid: getpid(), name: "RubberMAC")
            func seen() -> (accessibility: Bool, bringBack: Bool) {
                offMain {
                    let element = AX.app(getpid())
                    AXUIElementSetMessagingTimeout(element, 1)
                    var value: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
                    let listed = (value as? [AXUIElement] ?? []).contains { AX.windowID(of: $0) == number }
                    return (listed, WindowResetMover.ordinaryWindows(of: [me]).contains { AX.windowID(of: $0.element) == number })
                }
            }
            let here = seen()
            check(here.accessibility && here.bringBack, "a window on this desktop: Accessibility lists it and Bring Back looks at it")
            SpaceWindows.move(number, to: other)
            pump(0.5)
            let moved = SpaceWindows.windows(of: [getpid()], on: [other])?.contains { $0.id == number } == true
            let there = seen()
            check(moved && !there.bringBack, "moved to another desktop: Bring Back leaves it alone; Accessibility "
                  + (there.accessibility ? "still lists it" : "no longer lists it"))
            window.orderOut(nil)
            ownWindow = nil
        }

        // Your windows, counted and not moved.
        func dryRun(_ screens: [ScreenArea], scratch: pid_t) {
            let windows = WindowResetMover.ordinaryWindows(of: WindowResetMover.appsInUse().filter { $0.pid != scratch })
            let before = windows.map(\.frame)
            let outcome = WindowResetMover.bringBack(windows, screens: screens, apply: false)
            let after = windows.map { AX.frame(of: $0.element) ?? .null }
            note("a press now would move \(outcome.lost.count) of the \(outcome.checked) windows of yours on this desktop")
            check(before == after, "counting them moved none of them")
        }

        // MARK: Forget

        func forgetChecks(_ first: NSRunningApplication) {
            // The real folders, with only the scratch app offered: so no other app's file is opened here.
            let real = WindowResetSavedFrames.realPlaces()
            let places = WindowResetSavedFrames.Places(preferences: real.preferences, savedState: real.savedState, containers: nil)
            let resolve: (String) -> (name: String, url: URL)? = { [self] in $0 == id ? (WindowResetScratchApp.name, app) : nil }
            var entry: WindowResetSavedFrames.App?
            let found = waitFor(10) {
                entry = WindowResetSavedFrames.scan(places, resolve: resolve).apps.first { $0.bundleID == id }
                return entry?.keys == ["NSSplitView Subview Frames Sidebar", "NSWindow Frame Main"]
            }
            check(found != nil && entry?.unread == false, "the list, over this Mac's preferences folder, has the scratch app with its window "
                  + "and split view sizes: \(entry?.keys ?? [])")
            // What the real list costs, less opening the files: finding the app behind each preferences file. Reads only
            // apps' own Info.plist files, in the folders apps are installed in.
            let started = Date()
            let names = (try? fm.contentsOfDirectory(atPath: real.preferences.path))?.filter { $0.hasSuffix(".plist") } ?? []
            let offered = names.filter { WindowResetSavedFrames.installedApp(String($0.dropLast(6))) != nil }.count
            note("finding the apps behind \(names.count) preferences files took \(Int(-started.timeIntervalSinceNow * 1000)) ms; "
                 + "\(offered) are installed apps. Full Disk Access is \(WindowResetSavedFrames.hasFullDiskAccess ? "on" : "off")"
                 + " (containers aren't read here either way)")
            guard var entry else { return }
            let kept = waitFor(8) { fm.fileExists(atPath: savedState.path) }
            note("saved windows from AppKit while it runs: " + (kept.map { "after \($0) ms" } ?? "none in 8 s, so the test made the folder"))
            if kept == nil {
                try? fm.createDirectory(at: savedState, withIntermediateDirectories: true)
                try? Data().write(to: savedState.appendingPathComponent("made-by-the-test"))
            }
            entry.hasSavedState = true

            // Quitting it is an Apple event, which macOS lets RubberMAC send only once the user has said yes for this app.
            // The test asks that only when told to (ask as the last argument), with someone there to answer.
            let permission = WindowResetForget.Steps.mayQuit(first.processIdentifier, ask: CommandLine.arguments.last == "ask")
            if permission == noErr { return openChecks(entry, first) }
            note("quitting it needs your yes for Automation first (status \(permission)); run again with ask at the end to answer it. "
                 + "So the test closes it itself, and forgetting, the Trash and opening it again are the real steps")
            closedChecks(entry, first)
        }

        // Steps with the Trash's result kept, so the cleanup can take it back out.
        func realSteps() -> WindowResetForget.Steps {
            var steps = WindowResetForget.Steps.real()
            let trash = steps.trash
            steps.trash = { [self] url in
                let result = trash(url)
                if case .moved(let to) = result { trashed = to }
                return result
            }
            return steps
        }

        // Open: once while it says no to quitting, then quit, forgotten and opened again by the flow itself.
        func openChecks(_ entry: WindowResetSavedFrames.App, _ first: NSRunningApplication) {
            try? Data().write(to: control.appendingPathComponent("refuse"))
            let before = keys()
            let no = offMain { WindowResetForget.run(entry, .real(quitWait: 5)) }
            check(no.quit == .stillOpen && alive(first.processIdentifier) && scratchApps.count == 1 && keys() == before
                  && fm.fileExists(atPath: savedState.path), "while it won't quit: nothing deleted, trashed or reopened — \(no.note(entry.name))")
            try? fm.removeItem(at: control.appendingPathComponent("refuse"))

            let began = Date()
            let steps = realSteps()
            let done = offMain { WindowResetForget.run(entry, steps) }
            check(done.quit == .quit && done.removed >= 2 && done.failed == 0 && done.reopened && !alive(first.processIdentifier),
                  "quit and forgot in \(Int(-began.timeIntervalSinceNow * 1000)) ms: \(done.note(entry.name)) (\(done.removed) frames)")
            freshChecks(first, before: before)
        }

        // Closed by the test (it's the test's own app): the real flow for an app that isn't open, then the flow's own
        // step for opening it again.
        func closedChecks(_ entry: WindowResetSavedFrames.App, _ first: NSRunningApplication) {
            first.forceTerminate()
            check(waitFor(5) { !alive(first.processIdentifier) } != nil, "the test closed its scratch app")
            let before = keys()
            let steps = realSteps()
            let done = offMain { WindowResetForget.run(entry, steps) }
            check(done.quit == .quit && done.removed == 2 && done.failed == 0 && !done.reopened,
                  "forgot through defaults: \(done.note(entry.name)) (\(done.removed) frames)")
            check(keys() == before.filter { !WindowResetSavedFrames.isFrameKey($0) }, "only its window sizes went: \(keys())")
            steps.reopen(entry.url)
            freshChecks(first, before: before)
        }

        func freshChecks(_ first: NSRunningApplication, before: [String]) {
            check(trashed.map { fm.fileExists(atPath: $0.path) && $0.path.contains("/.Trash/") } == true,
                  "its saved windows are in the Trash: \(trashed?.lastPathComponent ?? "not moved")")
            var again: NSRunningApplication?
            var windows: [WindowResetMover.Window] = []
            let back = waitFor(15) {
                again = scratchApps.first { $0.processIdentifier != first.processIdentifier }
                windows = again.map { scratchWindows($0.processIdentifier) } ?? []
                return windows.count == 3
            }
            check(back != nil, "it opened again (\(again.map { _ in "with \(windows.count) windows" } ?? "not running"))")
            let main = window("Main", in: windows)?.frame
            check(main.map { abs($0.width - WindowResetScratchApp.usualSize.width) <= 1 && abs($0.height - WindowResetScratchApp.usualSize.height) <= 1 } == true,
                  "its window opened fresh, at its usual size, not the one it had saved: \(text(main))")
            let after = keys()
            check(before.filter { !WindowResetSavedFrames.isFrameKey($0) }.allSatisfy(after.contains),
                  "its other settings are still there: \(after.filter { !WindowResetSavedFrames.isFrameKey($0) })")
        }

        // MARK: Cleaning up

        func cleanUp() {
            ownWindow?.orderOut(nil)
            for running in scratchApps { running.terminate() }
            if waitFor(8, { scratchApps.isEmpty }) == nil { scratchApps.forEach { $0.forceTerminate() } }
            _ = waitFor(5) { scratchApps.isEmpty }
            _ = WindowResetForget.Steps.defaults(["delete", id])
            try? fm.removeItem(at: savedState)
            if let trashed { try? fm.removeItem(at: trashed) }
            _ = WindowResetScratchApp.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                                          ["-u", app.path])
            try? fm.removeItem(at: folder)
            previous?.activate()
            pump(0.5)
            let plist = WindowResetSavedFrames.realPlaces().preferences.appendingPathComponent("\(id).plist")
            if fm.fileExists(atPath: plist.path) { try? fm.removeItem(at: plist) }

            check(scratchApps.isEmpty && keys().isEmpty && !fm.fileExists(atPath: plist.path) && !fm.fileExists(atPath: savedState.path)
                  && !fm.fileExists(atPath: folder.path) && trashed.map { !fm.fileExists(atPath: $0.path) } != false,
                  "cleaned up: the scratch app quit, its preferences, saved windows, Trash item and folder are gone")
            let after = Self.settings(domain)
            check(stored?.isEqual(after) ?? (after == nil), "no stored setting changed")
        }
    }
}
