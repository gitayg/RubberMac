import AppKit
import Security

// Downloads a release, checks it, and swaps it in for the installed app. No UI, so the self-test can drive it.
enum UpdateInstaller {
    // The running copy's own requirement, as macOS reads it from the signature: this app, signed with the same
    // developer's Developer ID. The Accessibility grant is tied to the same signature, so an update that passes keeps
    // working without asking again. Nil for an unsigned copy, and then nothing passes.
    static func ownRequirement() -> SecRequirement? {
        var running: SecCode?
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    enum Failure: LocalizedError {
        case feed(Int), noApp, wrongVersion(String), untrusted, notWritable, unzip

        var errorDescription: String? {
            switch self {
            case .feed(let status): return "release feed answered HTTP \(status)"
            case .noApp: return "the download has no app in it"
            case .wrongVersion(let version): return "the download is version \(version.isEmpty ? "?" : version)"
            case .untrusted: return "the download isn't signed by RubberMAC's developer"
            case .notWritable: return "can't replace the app where it is installed"
            case .unzip: return "couldn't unpack the download"
            }
        }
    }

    // nil when nothing has been released yet.
    static func latest() async throws -> UpdateFeed.Release? {
        var request = URLRequest(url: UpdateFeed.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw Failure.feed(status) }
        return UpdateFeed.parse(data)
    }

    static func install(_ release: UpdateFeed.Release, over app: URL, current: String) async throws {
        let files = FileManager.default
        guard files.isWritableFile(atPath: app.deletingLastPathComponent().path) else { throw Failure.notWritable }
        // On the app's own volume, so the final swap is a rename.
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? files.removeItem(at: work) }
        let (download, _) = try await URLSession.shared.download(from: release.zipURL)
        let zip = work.appendingPathComponent("update.zip")
        try files.moveItem(at: download, to: zip)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw Failure.unzip }

        guard let new = try files.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw Failure.noApp }
        let version = self.version(of: new) ?? ""
        guard version == release.version, UpdateFeed.isNewer(version, than: current) else {
            throw Failure.wrongVersion(version)
        }
        guard isTrusted(new) else { throw Failure.untrusted }
        _ = try files.replaceItemAt(app, withItemAt: new)
    }

    static func isTrusted(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              let requirement = ownRequirement() else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    // Read straight from the file: Bundle caches by path, and the path stays the same across an update.
    static func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    // Opens the app again once this process has gone.
    static func relaunch(_ app: URL) {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"",
                           "\(ProcessInfo.processInfo.processIdentifier)", app.path]
        try? shell.run()
        NSApp.terminate(nil)
    }

    // "check" only reads the feed; "install" also updates the app this runs from (run it on a copy).
    static func selfTestReport(install: Bool) -> String {
        final class Box: @unchecked Sendable { var lines: [String] = [] }
        let box = Box()
        let app = Bundle.main.bundleURL
        let current = version(of: app) ?? "0"
        box.lines.append("running: \(current) at \(app.path)")
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                if let release = try await latest() {
                    box.lines.append("feed: \(release.version) \(release.zipURL.absoluteString)")
                    let newer = UpdateFeed.isNewer(release.version, than: current)
                    box.lines.append("newer: \(newer)")
                    if install && newer {
                        try await self.install(release, over: app, current: current)
                        box.lines.append("installed: \(version(of: app) ?? "?"), trusted: \(isTrusted(app))")
                    }
                } else {
                    box.lines.append("feed: no release yet")
                }
            } catch {
                box.lines.append("error: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
        return box.lines.joined(separator: "\n")
    }
}
