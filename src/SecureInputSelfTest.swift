import AppKit
import Carbon.HIToolbox

// --selftest secureinput: the Secure Input notice on made-up holders and states. Who it names, the words, the
// keyboard tap's watcher (only ⌘, Ctrl and Alt, at most once a second, never changing an event), one log line per
// episode, the notice on the General and Keyboard pages and the menu-bar badge. Reads nothing real but the cost of
// IsSecureEventInputEnabled and the kernel's executable for this process and the login window, posts no keys and
// shows nothing.
extension SecureInput {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        NSApp.setActivationPolicy(.accessory)
        let teams = Holder(pid: 80752, name: "Microsoft Teams", bundleID: "com.microsoft.teams2")
        let login = Holder(pid: 412, name: "loginwindow", bundleID: Holder.loginWindowBundleID)
        let unknown = Holder(pid: 812, name: nil, bundleID: nil)

        namingChecks(check, teams: teams, login: login, unknown: unknown)
        kernelChecks(check)
        registryChecks(check)
        noticeChecks(check, teams: teams, login: login, unknown: unknown)
        let cost = tapChecks(check)
        lines.append(cost)
        monitorChecks(check, teams: teams)
        pageChecks(check, teams: teams)
        iconChecks(check)
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    private typealias Check = (Bool, String) -> Void

    private static func namingChecks(_ check: Check, teams: Holder, login: Holder, unknown: Holder) {
        check(teams.displayName == "Microsoft Teams", "an app is named by its name (\(teams.displayName))")
        check(teams.logDescription == "Microsoft Teams (com.microsoft.teams2, pid 80752)",
              "the log gives its name, bundle ID and pid (\(teams.logDescription))")
        check(teams.canBeShown, "and it can be brought to the front")
        check(login.displayName == "a login window" && !login.canBeShown, "the login window is “a login window”, with nothing to show")
        check(Holder(pid: 9, name: "loginwindow", bundleID: nil).isLoginWindow, "so is a loginwindow known only by its name")
        check(unknown.displayName == "a background process (pid 812)" && !unknown.canBeShown,
              "a pid that's no running app says so (\(unknown.displayName))")
        check(unknown.logDescription == "pid 812, not a running app", "and the log says it plainly (\(unknown.logDescription))")
    }

    // When macOS's list of running apps has no app for the pid, the kernel still knows what it runs.
    private static func kernelChecks(_ check: Check) {
        check(loginWindowID(running: loginWindowExecutable) == Holder.loginWindowBundleID
              && loginWindowID(running: "/usr/sbin/sshd") == nil && loginWindowID(running: nil) == nil,
              "the login window's executable means the login window, and no other does")
        func real(_ path: String?) -> String? { path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        let mine = executablePath(of: getpid())
        check(mine != nil && real(mine) == real(Bundle.main.executablePath), "the kernel gives this process's executable (\(mine ?? "none"))")
        let gone = (1...99_999).reversed().first { kill(pid_t($0), 0) == -1 && errno == ESRCH }.map { pid_t($0) }
        check(gone.map { executablePath(of: $0) == nil } == true, "and none for a pid no process has (\(gone.map(String.init) ?? "none free"))")
        if let window = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Holder.loginWindowBundleID }) {
            let path = executablePath(of: window.processIdentifier)
            check(path == loginWindowExecutable, "the running login window's executable is the one it's known by (\(path ?? "none"))")
        } else {
            check(false, "a login window is running")
        }
        let read = holder(pid: 424, app: nil, path: { loginWindowExecutable })
        check(read.isLoginWindow && read.displayName == "a login window" && !read.canBeShown,
              "a pid missing from the running apps but running loginwindow is the login window (\(read.logDescription))")
        check(holder(pid: 812, app: nil, path: { "/usr/sbin/sshd" }) == Holder(pid: 812, name: nil, bundleID: nil),
              "any other is still a background process")
        var asked = false
        let me = holder(pid: getpid(), app: NSRunningApplication.current, path: { asked = true; return nil })
        check(me.bundleID == Bundle.main.bundleIdentifier && !asked, "a running app is named by macOS's list, without asking the kernel")
    }

    private static func registryChecks(_ check: Check) {
        let me: uid_t = 502
        func user(_ uid: uid_t, _ pid: Any?) -> [String: Any] {
            var entry: [String: Any] = ["kCGSSessionUserIDKey": NSNumber(value: uid), "kCGSSessionOnConsoleKey": true]
            if let pid { entry["kCGSSessionSecureInputPID"] = pid }
            return entry
        }
        check(holderPID(in: [user(me, NSNumber(value: 80752))], uid: me) == 80752, "the pid is read from this user's entry")
        check(holderPID(in: [user(501, NSNumber(value: 77)), user(me, NSNumber(value: 80752))], uid: me) == 80752,
              "this user's entry wins over another user's")
        check(holderPID(in: [user(501, NSNumber(value: 77)), user(me, nil)], uid: me) == 77,
              "failing that, any entry that holds it (the login window before anyone has logged in)")
        check(holderPID(in: [user(me, nil)], uid: me) == nil, "no key: nobody holds it")
        check(holderPID(in: [user(me, NSNumber(value: 0))], uid: me) == nil, "a pid of 0 is nobody")
        check(holderPID(in: [], uid: me) == nil, "no console users: nobody")
    }

    private static func noticeChecks(_ check: Check, teams: Holder, login: Holder, unknown: Holder) {
        let notice = Notice.text(for: teams)
        check(notice.title == "Microsoft Teams has Secure Input on", "the notice names the app (\(notice.title))")
        let stops = ["window snapping", "⌘R", "Ctrl-C/V", "Alt-Tab", "⌘, Ctrl or Alt"].filter { !notice.body.contains($0) }
        check(stops.isEmpty, "it says what stops working\(stops.isEmpty ? "" : ", missing \(stops)")")
        check(notice.body.hasSuffix("Close any password or sign-in prompt in Microsoft Teams, or quit it and open it again."),
              "and how to fix it in that app")
        check(notice.button == "Show", "with a button that brings it to the front")
        let loginNotice = Notice.text(for: login)
        check(loginNotice.title == "A login window has Secure Input on" && loginNotice.button == nil
              && loginNotice.body.contains("Lock the screen and unlock it again"), "a login window gets its own fix and no button")
        check(loginNotice.hoverText.hasPrefix(loginNotice.title + ". ") && loginNotice.hoverText.hasSuffix(loginNotice.body),
              "the icon's tooltip says the same as the card, title then how to get the keys back")
        let unknownNotice = Notice.text(for: unknown)
        check(unknownNotice.title == "A background process (pid 812) has Secure Input on" && unknownNotice.button == nil,
              "an unnamed pid is said plainly, with no button (\(unknownNotice.title))")
        let none = Notice.text(for: nil)
        check(none.title == "An app has Secure Input on" && none.button == nil, "with no pid at all it still says what's wrong")
    }

    // Returns a note with what a press costs the tap.
    private static func tapChecks(_ check: Check) -> String {
        final class Other: TapHandler {
            var isActive = true
            func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? { event }
        }
        func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        func event(_ type: CGEventType, _ flags: CGEventFlags, key: Int = kVK_Command) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true)!
            event.type = type
            event.flags = flags
            return event
        }
        let other = Other()
        let keys = SecureInputKeys()
        let handlers = keys.watching([other])
        check(handlers.first === keys && handlers.count == 2, "it goes first in the keyboard tap, before the ones it watches")
        var secure = true
        var clock: TimeInterval = 100
        var seen = 0
        keys.secureInput = { secure }
        keys.now = { clock }
        keys.onSeen = { seen += 1 }

        let command = event(.flagsChanged, .maskCommand)
        check(keys.handle(.flagsChanged, command) === command, "it passes ⌘ on unchanged")
        pump()
        check(seen == 1, "⌘ going down while Secure Input is on tells the main thread (\(seen))")
        clock += 0.5
        _ = keys.handle(.flagsChanged, event(.flagsChanged, .maskControl))
        pump()
        check(seen == 1, "again within a second: not again (\(seen))")
        clock += 0.6
        _ = keys.handle(.flagsChanged, event(.flagsChanged, .maskAlternate))
        pump()
        check(seen == 2, "Ctrl, then Alt a second later: told again (\(seen))")
        clock += 5
        _ = keys.handle(.flagsChanged, event(.flagsChanged, .maskShift))
        _ = keys.handle(.flagsChanged, event(.flagsChanged, []))
        let down = event(.keyDown, .maskCommand, key: kVK_RightArrow)
        check(keys.handle(.keyDown, down) === down, "a key is passed on unchanged")
        pump()
        check(seen == 2, "Shift, a modifier let go and a key don't count (\(seen))")
        secure = false
        _ = keys.handle(.flagsChanged, command)
        pump()
        check(seen == 2, "with Secure Input off, ⌘ tells nobody (\(seen))")
        check(keys.isActive, "it's on while a handler it watches is")
        other.isActive = false
        check(!keys.isActive, "and off with every keyboard feature off, so it never keeps the tap running on its own")

        // Cost on the tap's thread, with Secure Input off (the usual case) and while it's on but just reported.
        let runs = 200_000
        func perEvent(_ work: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<runs { work() }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(runs)
        }
        let system = perEvent { _ = IsSecureEventInputEnabled() }
        let real = SecureInputKeys()
        real.onSeen = {}
        real.secureInput = { false }
        let offCost = perEvent { _ = real.handle(.flagsChanged, command) }
        real.secureInput = { true }
        _ = real.handle(.flagsChanged, command)
        let throttledCost = perEvent { _ = real.handle(.flagsChanged, command) }
        pump()
        check(offCost + system < 20_000 && throttledCost < 20_000, "a ⌘, Ctrl or Alt press costs the tap under 20 µs")
        return String(format: "note: IsSecureEventInputEnabled %.0f ns; a ⌘ press costs %.0f ns with Secure Input off, %.0f ns while on and just reported",
                      system, offCost + system, throttledCost)
    }

    private static func monitorChecks(_ check: Check, teams: Holder) {
        let monitor = SecureInputMonitor()
        var log: [String] = []
        var changes = 0
        var pending: [() -> Void] = []
        var on = true
        var watching = true
        var holder: Holder? = teams
        monitor.isOn = { on }
        monitor.isWatching = { watching }
        monitor.readHolder = { holder }
        monitor.write = { log.append($0) }
        monitor.onChange = { changes += 1 }
        var delays: Set<TimeInterval> = []
        monitor.schedule = { delay, work in
            delays.insert(delay)
            pending.append(work)
        }
        func tick() {
            let due = pending
            pending = []
            due.forEach { $0() }
        }

        monitor.noteOn()
        check(monitor.isShowing && monitor.holder == teams && changes == 1, "a ⌘ press while it's on puts the notice up")
        check(log == ["secure input: on, held by Microsoft Teams (com.microsoft.teams2, pid 80752); keys pressed with ⌘, Ctrl or Alt can't be seen"],
              "with one log line naming the holder (\(log.last ?? "none"))")
        monitor.noteOn()
        monitor.noteOn()
        check(log.count == 1 && changes == 1 && pending.count == 1, "more presses: no more lines, and one check waiting (\(log.count), \(pending.count))")
        tick()
        check(monitor.isShowing && log.count == 1 && pending.count == 1, "still on at the check: still up, quietly, checked again")
        holder = Holder(pid: 1037, name: "Google Chrome", bundleID: "com.google.Chrome")
        tick()
        check(monitor.holder?.name == "Google Chrome" && log.last == "secure input: now held by Google Chrome (com.google.Chrome, pid 1037)" && changes == 2,
              "another app taking it over is said once (\(log.last ?? "none"))")
        on = false
        tick()
        check(!monitor.isShowing && monitor.notice == nil && changes == 3, "off at the check: the notice comes down")
        check(log.last == "secure input: off, keys pressed with ⌘, Ctrl or Alt are seen again" && log.count == 3,
              "with one line saying so (\(log.last ?? "none"))")
        check(pending.isEmpty, "and no timer runs while it's off")
        monitor.noteOn()
        check(!monitor.isShowing && log.count == 3, "a ⌘ press with Secure Input off does nothing")

        on = true
        watching = false
        monitor.noteOn()
        check(!monitor.isShowing && log.count == 3 && pending.isEmpty, "with no keyboard feature on, no notice and no timer")
        watching = true
        holder = teams
        monitor.noteOn()
        watching = false
        tick()
        check(!monitor.isShowing && log.last == "secure input: notice taken down, no keyboard feature is on" && pending.isEmpty,
              "turning the keyboard features off takes it down at the next check")
        watching = true
        holder = nil
        monitor.noteOn()
        check(monitor.notice?.title == "An app has Secure Input on"
              && log.last?.hasPrefix("secure input: on, held by an app RubberMAC couldn't name") == true,
              "a holder that can't be read still puts the notice up (\(log.last ?? "none"))")
        let login = Holder(pid: 424, name: "loginwindow", bundleID: Holder.loginWindowBundleID)
        holder = login
        tick()
        let said = (log.count, changes)
        holder = Holder(pid: 424, name: nil, bundleID: nil)
        tick()
        let during = monitor.notice?.title
        holder = login
        tick()
        check(monitor.holder == login && during == "A login window has Secure Input on" && log.count == said.0 && changes == said.1,
              "one read that can't name the same pid keeps its name: no change of holder and back (\(log.suffix(2)), \(during ?? "no notice"))")
        on = false
        tick()
        on = true
        holder = Holder(pid: 424, name: nil, bundleID: Holder.loginWindowBundleID)
        monitor.noteOn()
        let first = (log.last, monitor.notice?.title)
        let lines = log.count
        holder = login
        tick()
        check(first.0 == "secure input: on, held by a login window (pid 424); keys pressed with ⌘, Ctrl or Alt can't be seen"
              && first.1 == "A login window has Secure Input on" && log.count == lines && monitor.holder == login,
              "a first read only the kernel could name says a login window, and the next naming it again adds no line (\(log.suffix(2)))")
        check(delays == [SecureInputMonitor.recheckInterval], "each check is \(SecureInputMonitor.recheckInterval) s after the last (\(delays.sorted()))")
    }

    private static func pageChecks(_ check: Check, teams: Holder) {
        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        let monitor = SecureInputMonitor.shared
        monitor.isOn = { true }
        monitor.isWatching = { true }
        monitor.readHolder = { teams }
        monitor.write = { _ in }
        monitor.schedule = { _, _ in }
        monitor.onChange = {}
        func page(_ id: String) -> SettingsPage? { delegate.settingsPages(SettingsFacts()).first { $0.id == id } }

        check(page("general")?.sections.contains { $0.title == Notice.sectionTitle } == false
              && page("keyboard")?.sections.contains { $0.title == Notice.sectionTitle } == false, "no notice on the pages while it's off")
        monitor.noteOn()
        for id in ["general", "keyboard"] {
            let section = page(id)?.sections.first
            let row = section?.rows.first
            check(section?.title == Notice.sectionTitle && row?.title == "Microsoft Teams has Secure Input on",
                  "on the \(id) page it comes first (\(section?.title ?? "-"): \(row?.title ?? "-"))")
            if case .button(let label, enabled: true)? = row?.control {
                check(label == "Show" && row?.action == #selector(AppDelegate.showSecureInputHolder)
                      && (row?.target as? NSObject)?.responds(to: #selector(AppDelegate.showSecureInputHolder)) == true
                      && row?.closesPanel == true, "with a Show button that reaches the delegate and gets the panel out of the way")
            } else {
                check(false, "with a Show button (the \(id) row has \(String(describing: row?.control)))")
            }
        }
        check(page("windows")?.sections.contains { $0.title == Notice.sectionTitle } == false, "but not on the other pages")
        monitor.readHolder = { Holder(pid: 412, name: "loginwindow", bundleID: Holder.loginWindowBundleID) }
        monitor.check()
        if case .none? = page("keyboard")?.sections.first?.rows.first?.control {
            check(true, "a login window's notice has no button")
        } else {
            check(false, "a login window's notice has no button")
        }
        monitor.isOn = { false }
        monitor.check()
        check(page("general")?.sections.contains { $0.title == Notice.sectionTitle } == false
              && page("keyboard")?.sections.contains { $0.title == Notice.sectionTitle } == false, "and it's gone once Secure Input is off")
    }

    private static func iconChecks(_ check: Check) {
        func pixel(_ image: NSImage, at point: NSPoint) -> NSColor? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = NSSize(width: 18, height: 18)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            NSGraphicsContext.restoreGraphicsState()
            return rep.colorAt(x: Int(point.x * 2), y: 36 - 1 - Int(point.y * 2))
        }
        let plain = StatusIcon.image()
        let blocked = StatusIcon.image(secureInputHolder: "Microsoft Teams")
        check(plain.isTemplate && !blocked.isTemplate, "the icon stays a template image until the badge needs its colour")
        check(blocked.accessibilityDescription == "RubberMAC, keys blocked by Secure Input in Microsoft Teams",
              "VoiceOver hears who's blocking the keys (\(blocked.accessibilityDescription ?? "none"))")
        let both = StatusIcon.image(eyeColor: .systemBlue, secureInputHolder: "Microsoft Teams")
        check(both.accessibilityDescription == "RubberMAC, Eye Color Camera on, keys blocked by Secure Input in Microsoft Teams",
              "and both, with the Eye Color Camera on")
        // Left of the "!" inside the disc.
        let spot = NSPoint(x: SecureInputBadge.disc.minX + 1.5, y: SecureInputBadge.disc.midY)
        let orange = NSColor.systemOrange.usingColorSpace(.deviceRGB)!
        func isOrange(_ color: NSColor?) -> Bool {
            guard let color else { return false }
            return abs(color.redComponent - orange.redComponent) < 0.1 && abs(color.greenComponent - orange.greenComponent) < 0.1
                && abs(color.blueComponent - orange.blueComponent) < 0.1 && color.alphaComponent > 0.9
        }
        func describe(_ color: NSColor?) -> String {
            color.map { String(format: "%.2f %.2f %.2f %.2f", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent) } ?? "no pixel"
        }
        let badge = pixel(blocked, at: spot)?.usingColorSpace(.deviceRGB)
        check(isOrange(badge), "the badge is drawn in orange, top right (\(describe(badge)))")
        let without = pixel(plain, at: spot)?.usingColorSpace(.deviceRGB)
        check(without != nil && !isOrange(without), "and isn't there without Secure Input (\(describe(without)))")
        let eyeOnly = pixel(StatusIcon.image(eyeColor: .systemBlue), at: spot)?.usingColorSpace(.deviceRGB)
        check(eyeOnly != nil && !isOrange(eyeOnly), "nor with only the eye colour's dot (\(describe(eyeOnly)))")
    }
}
