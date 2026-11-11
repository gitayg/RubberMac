import AppKit
import Carbon.HIToolbox

// Delete in Finder moves what's highlighted to the Trash, as on a PC, by pressing Finder's own ⌘⌫, so ⌘Z puts it back.
// Either delete key will do: ⌦, or the ⌫ of a Mac keyboard. Typing (renaming, search, Go to Folder, the address bar, the
// writing pad) keeps its delete key.
final class FinderTrashKey: TapHandler {
    var isEnabled = false
    var isActive: Bool { isEnabled }

    // The delete key whose press became a ⌘⌫; its repeats and its release go too.
    private var taken: Int?

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, type == .keyDown || type == .keyUp else { return event }
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard key == kVK_ForwardDelete || key == kVK_Delete else { return event }
        if type == .keyUp {
            guard taken == key else { return event }
            taken = nil
            return nil
        }
        // Holding it down mustn't go on to trash whatever Finder highlights next.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return taken == key ? nil : event }
        guard Self.trashes(flags: event.flags.rawValue, app: Frontmost.bundleID, ownWindowIsKey: Frontmost.ownWindowIsKey),
              FinderPathPaste.isEditingText(in: Frontmost.pid) == false else { return event }
        taken = key
        DispatchQueue.main.async { Paster.press(kVK_Delete, flags: .maskCommand) }
        return nil
    }

    func tapWasDisabled() {
        taken = nil
    }

    // ownWindowIsKey: the address bar and the writing pad take keys while Finder stays the app in front.
    static func trashes(flags: UInt64, app: String?, ownWindowIsKey: Bool) -> Bool {
        let held = Modifiers.command | Modifiers.control | Modifiers.option | Modifiers.shift
        return flags & held == 0 && app == "com.apple.finder" && !ownWindowIsKey
    }
}
