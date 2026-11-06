import AppKit

// --selftest permissions: when RubberMAC asks for Screen Recording by itself, and what each message says. Shows nothing
// and asks for nothing.
extension PermissionRequest {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }

        check(screenRecordingDue(hasPermission: false, alreadyAsked: false, accessibilityDone: true),
              "it asks for Screen Recording when it lacks it, hasn't asked, and Accessibility is settled")
        check(!screenRecordingDue(hasPermission: false, alreadyAsked: true, accessibilityDone: true), "only once")
        check(!screenRecordingDue(hasPermission: true, alreadyAsked: false, accessibilityDone: true), "not when it has it")
        check(!screenRecordingDue(hasPermission: false, alreadyAsked: false, accessibilityDone: false),
              "not while Accessibility is still open, so the two don't pile up")

        for (request, name, reason) in [(PermissionRequest.accessibility, "accessibility", "Alt-Tab"),
                                        (.screenRecording, "screen-recording", "picture of each window")] {
            let alert = request.alert()
            check(alert.informativeText.contains(reason), "\(name): says what it's for (\(reason))")
            check(alert.informativeText.contains("Without it"), "\(name): says what happens without it")
            check(alert.informativeText.contains("leaves your Mac"), "\(name): says nothing leaves the Mac")
            check(alert.buttons.map(\.title) == ["Continue", "Not Now"], "\(name): can be put off")
        }
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
