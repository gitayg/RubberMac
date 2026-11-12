import Carbon.HIToolbox
import CoreGraphics
import Foundation

// ⌘L locks the screen at once, like Win+L on a PC. It's the call the Apple menu's Lock Screen makes
// (SACLockScreenImmediate in the private login framework): no screen saver, no delay setting involved.
enum ScreenLock {
    private typealias LockNow = @convention(c) () -> Int32

    private static let lockNow: LockNow? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockNow.self)
    }()

    static var isAvailable: Bool { lockNow != nil }

    static var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    static func lock() {
        guard let lockNow else {
            // A macOS without the call: press the system's own Lock Screen shortcut instead.
            log("lock screen: no SACLockScreenImmediate, pressing ⌃⌘Q")
            Paster.press(kVK_ANSI_Q, flags: [.maskControl, .maskCommand])
            return
        }
        let status = lockNow()
        log("lock screen: ⌘L (\(status))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { log("lock screen: \(isLocked ? "locked" : "didn't lock")") }
    }

    /// --selftest screenlock: the lock call is there (it isn't called: that would lock the screen) and ⌘L can be taken
    /// as a hotkey. The lock itself is checked by pressing ⌘L and reading "lock screen: locked" in the log.
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        check(isAvailable, "macOS has the call Lock Screen makes")
        check(!isLocked, "it reads the screen as unlocked now")
        let keys = HotKeys()
        check(keys.register(keyCode: kVK_ANSI_L, modifiers: cmdKey) {}, "⌘L can be registered as a hotkey, taking it from every app")
        keys.unregisterAll()
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
