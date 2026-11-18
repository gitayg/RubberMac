import AppKit

// --selftest secureinput-live: reads the real Secure Input state and who holds it, the way the notice does. No UI and
// no keys posted; it prints what it found, and checks that the two ways of asking agree.
extension SecureInput {
    static func liveSelfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        let on = isOn()
        let registry = registryHolderPID()
        let session = sessionHolderPID()
        let pid = holderPID()
        let found = holder()
        func name(_ pid: pid_t?) -> String {
            pid.map { "\($0) (\(NSRunningApplication(processIdentifier: $0)?.localizedName ?? "not a running app"))" } ?? "none"
        }
        lines.append("Secure Input: \(on ? "on" : "off")")
        lines.append("I/O Registry holder pid: \(name(registry))")
        lines.append("session dictionary holder pid: \(name(session))\(registry != session ? " — differs" : "")")
        lines.append("holder: \(found.map { "\($0.logDescription), shown as “\($0.displayName)”" } ?? "none")")
        check(on == (pid != nil), "IsSecureEventInputEnabled and the holder pid agree (\(on) / \(pid != nil))")
        if let found, found.name != nil {
            check(NSRunningApplication(processIdentifier: found.pid) != nil, "the holder is a running app")
        }
        let notice = Notice.text(for: found)
        lines.append("notice: \(notice.title) — \(notice.body)")
        // The monitor on the real readers, with its log line kept here rather than in the log.
        let monitor = SecureInputMonitor()
        var written: [String] = []
        monitor.isWatching = { true }
        monitor.write = { written.append($0) }
        monitor.schedule = { _, _ in }
        monitor.noteOn()
        check(monitor.isShowing == on && monitor.notice == (on ? notice : nil),
              "the monitor, reading the real state, \(on ? "puts the notice up" : "puts nothing up")")
        lines.append("monitor would log: \(written.first ?? "nothing")")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
