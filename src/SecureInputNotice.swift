import AppKit

// What RubberMAC tells you while Secure Input hides the keys from it: who holds it, what stops working and how to
// get it back. Shown at the top of the General and Keyboard pages, and as a badge on the menu-bar icon.
extension SecureInput {
    struct Notice: Equatable {
        let title: String
        let body: String
        // The label of the button that brings the app to the front, nil when there's no app to show.
        let button: String?

        static let sectionTitle = "Secure Input Is On"
        static let stops = "While it's on, macOS hides the keys pressed with ⌘, Ctrl or Alt from RubberMAC, so window "
            + "snapping, ⌘R, Ctrl-C/V, Alt-Tab and the other keys stop working."

        static func text(for holder: Holder?) -> Notice {
            guard let holder else {
                return Notice(title: "An app has Secure Input on", body: stops + " Quitting the app you last typed a "
                              + "password in usually turns it off.", button: nil)
            }
            if holder.isLoginWindow {
                return Notice(title: "A login window has Secure Input on", body: stops + " Lock the screen and unlock it "
                              + "again; if that doesn't turn it off, log out and back in.", button: nil)
            }
            guard holder.canBeShown else {
                return Notice(title: "\(holder.displayName.prefix(1).uppercased() + holder.displayName.dropFirst()) has "
                              + "Secure Input on", body: stops + " Quitting the app you last typed a password in usually "
                              + "turns it off.", button: nil)
            }
            return Notice(title: "\(holder.displayName) has Secure Input on", body: stops + " Close any password or sign-in "
                          + "prompt in \(holder.displayName), or quit it and open it again.", button: "Show")
        }
    }
}

// Keeps the notice: put up when the keyboard tap sees ⌘, Ctrl or Alt go down while Secure Input is on, checked again
// every few seconds while it's up, and taken down once Secure Input is off. Nothing runs while it's off. Main thread.
final class SecureInputMonitor {
    static let shared = SecureInputMonitor()
    static let recheckInterval: TimeInterval = 3

    // While the notice is up; holder is nil then only if no pid could be read.
    private(set) var isShowing = false
    private(set) var holder: SecureInput.Holder?

    // The system's side, swapped out by the self-test.
    var isOn: () -> Bool = SecureInput.isOn
    var readHolder: () -> SecureInput.Holder? = SecureInput.holder
    // Whether the keyboard tap runs: with no keyboard feature on, Secure Input takes nothing from RubberMAC.
    var isWatching: () -> Bool = { false }
    var write: (String) -> Void = { log($0) }
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    var onChange: () -> Void = {}
    private var checkPending = false

    var notice: SecureInput.Notice? { isShowing ? .text(for: holder) : nil }

    // From the keyboard tap (and the ⌘ tap that couldn't be told from ⌘ pressed with a key).
    func noteOn() {
        guard isWatching(), isOn() else { return }
        let found = readHolder()
        if !isShowing {
            isShowing = true
            holder = found
            write("secure input: on, held by \(Self.describe(found)); keys pressed with ⌘, Ctrl or Alt can't be seen")
            onChange()
        } else if found != holder {
            holder = found
            write("secure input: now held by \(Self.describe(found))")
            onChange()
        }
        scheduleCheck()
    }

    // The timer's: still on, still watched?
    func check() {
        checkPending = false
        guard isShowing else { return }
        guard isWatching() else {
            clear("secure input: notice taken down, no keyboard feature is on")
            return
        }
        guard isOn() else {
            clear("secure input: off, keys pressed with ⌘, Ctrl or Alt are seen again")
            return
        }
        let found = readHolder()
        if found != holder {
            holder = found
            write("secure input: now held by \(Self.describe(found))")
            onChange()
        }
        scheduleCheck()
    }

    private func clear(_ line: String) {
        isShowing = false
        holder = nil
        write(line)
        onChange()
    }

    private func scheduleCheck() {
        guard !checkPending else { return }
        checkPending = true
        schedule(Self.recheckInterval) { [weak self] in self?.check() }
    }

    static func describe(_ holder: SecureInput.Holder?) -> String {
        holder?.logDescription ?? "an app RubberMAC couldn't name (no pid in the I/O Registry)"
    }
}
