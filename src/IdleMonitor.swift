import AppKit
import IOKit
import IOKit.pwr_mgt

final class IdleMonitor {
    private(set) var isLocked = false
    private(set) var saverRunning = false

    init() {
        let dnc = DistributedNotificationCenter.default()
        let watch: [(String, (IdleMonitor) -> Void)] = [
            ("com.apple.screenIsLocked", { $0.isLocked = true }),
            ("com.apple.screenIsUnlocked", { $0.isLocked = false }),
            ("com.apple.screensaver.didstart", { $0.saverRunning = true }),
            ("com.apple.screensaver.didstop", { $0.saverRunning = false }),
        ]
        for (name, apply) in watch {
            dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                if let self { apply(self) }
            }
        }
    }

    // Seconds since the last keyboard/mouse/trackpad event (same counter the screen saver uses).
    func idleSeconds() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)
        guard let ns = value?.takeRetainedValue() as? NSNumber else { return 0 }
        return ns.doubleValue / 1_000_000_000
    }

    // System Settings > Lock Screen > "Start Screen Saver when inactive", in seconds (0 = never).
    func saverTimeout() -> TimeInterval {
        let domain = "com.apple.screensaver" as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        let value = CFPreferencesCopyValue("idleTime" as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return (value as? NSNumber)?.doubleValue ?? 0
    }

    // A video call or movie holding a display-sleep assertion keeps the screen saver from starting.
    func displaySleepBlocked() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let dict = status?.takeRetainedValue() as? [String: Int] else { return false }
        return (dict["PreventUserIdleDisplaySleep"] ?? 0) > 0
    }
}
