import Foundation

// --selftest update-trust [app ...]: which downloads the update check accepts. A plain copy of this app passes; a copy
// with a changed file, and one signed ad hoc, don't; nor does any app named after it (say, one signed by the same
// developer for another bundle ID). Works on copies in a temporary folder. Needs no permission or network.
extension UpdateInstaller {
    static func trustSelfTestReport(others: [URL]) -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("update-trust-\(getpid())")
        defer { try? files.removeItem(at: folder) }
        func copy(_ name: String) -> URL? {
            let to = folder.appendingPathComponent(name).appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
            try? files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? files.copyItem(at: Bundle.main.bundleURL, to: to)) == nil ? nil : to
        }

        check(ownRequirement() != nil, "macOS gives this copy a requirement to check downloads against")
        check(copy("plain").map(isTrusted) == true, "a plain copy of this app passes")

        let altered = copy("altered")
        let plist = altered?.appendingPathComponent("Contents/Info.plist")
        if let plist, let handle = try? FileHandle(forWritingTo: plist) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\n".utf8))
            try? handle.close()
        }
        check(altered.map(isTrusted) == false, "a copy with a changed file doesn't")

        let adHoc = copy("ad-hoc")
        if let adHoc {
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", adHoc.path]
            sign.standardError = FileHandle.nullDevice
            try? sign.run()
            sign.waitUntilExit()
        }
        check(adHoc.map(isTrusted) == false, "a copy signed ad hoc doesn't")

        for (i, other) in others.enumerated() {
            let id = Bundle(url: other)?.bundleIdentifier ?? "?"
            check(!isTrusted(other), "app \(i + 1) (\(id)) doesn't")
        }
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
