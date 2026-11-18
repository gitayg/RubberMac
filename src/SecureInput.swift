import AppKit
import Carbon.HIToolbox
import IOKit

// Secure Input: while an app has it on (a password field, a sign-in prompt, a terminal's Secure Keyboard Entry),
// macOS hides the keys typed from every event tap. RubberMAC's keyboard tap still sees ⌘, Ctrl and Alt go down and
// up, but not the keys pressed with them, so window snapping, ⌘R, Ctrl-C/V, Alt-Tab and the rest stop working.
// The app holding it is named in the I/O Registry's console users, which is where `ioreg` finds it too.
enum SecureInput {
    struct Holder: Equatable {
        let pid: pid_t
        // nil when no running app has that pid (a background process, or one that quit since).
        let name: String?
        let bundleID: String?

        static let loginWindowBundleID = "com.apple.loginwindow"

        var isLoginWindow: Bool { bundleID == Self.loginWindowBundleID || name == "loginwindow" }

        // How the notice and the log name it: "Microsoft Teams", "a login window", "a background process (pid 812)".
        var displayName: String {
            if isLoginWindow { return "a login window" }
            if let name, !name.isEmpty { return name }
            return "a background process (pid \(pid))"
        }

        // For the log: the name, bundle ID and pid, whichever are known.
        var logDescription: String {
            if isLoginWindow { return "a login window (pid \(pid))" }
            guard let name, !name.isEmpty else { return "pid \(pid), not a running app" }
            return "\(name) (\(bundleID.map { "\($0), " } ?? "")pid \(pid))"
        }

        // Only a running app with a window can be brought to the front.
        var canBeShown: Bool { name != nil && !isLoginWindow }
    }

    static func isOn() -> Bool { IsSecureEventInputEnabled() }

    // The pid the I/O Registry gives for this user's console session, nil when none holds it. The session's own
    // dictionary carries the key too, but it was seen naming Chrome for a few seconds while the I/O Registry and ioreg
    // named Microsoft Teams throughout, so it's only the fallback.
    static func holderPID() -> pid_t? {
        registryHolderPID() ?? sessionHolderPID()
    }

    static func registryHolderPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        return holderPID(in: users, uid: getuid())
    }

    static func sessionHolderPID() -> pid_t? {
        (CGSessionCopyCurrentDictionary() as? [String: Any]).flatMap { holderPID(in: [$0], uid: getuid()) }
    }

    // The console users' entries, as the I/O Registry lists them. This user's session wins; failing that, any that
    // says it holds it (the login window, before anyone has logged in).
    static func holderPID(in users: [[String: Any]], uid: uid_t) -> pid_t? {
        func pid(_ user: [String: Any]) -> pid_t? {
            (user["kCGSSessionSecureInputPID"] as? NSNumber).map { pid_t($0.int32Value) }.flatMap { $0 > 0 ? $0 : nil }
        }
        let mine = users.filter { ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid }
        return mine.lazy.compactMap(pid).first ?? users.lazy.compactMap(pid).first
    }

    static func holder() -> Holder? {
        guard let pid = holderPID() else { return nil }
        return holder(pid: pid, app: NSRunningApplication(processIdentifier: pid), path: { executablePath(of: pid) })
    }

    static let loginWindowExecutable = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"

    // macOS's list of running apps names it; when the list has no app for the pid (it was seen missing the login
    // window for single reads), the kernel's executable for the pid still tells the login window apart.
    static func holder(pid: pid_t, app: NSRunningApplication?, path: () -> String?) -> Holder {
        Holder(pid: pid, name: app?.localizedName, bundleID: app?.bundleIdentifier ?? loginWindowID(running: path()))
    }

    // The executable the kernel has for a pid, nil when no process has it.
    static func executablePath(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(cString: path)
    }

    static func loginWindowID(running path: String?) -> String? {
        path == loginWindowExecutable ? Holder.loginWindowBundleID : nil
    }
}
