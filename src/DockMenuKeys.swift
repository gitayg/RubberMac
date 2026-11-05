import AppKit
import Carbon.HIToolbox
import Synchronization

// While the Dock's window menu is open, Esc closes it and goes no further.
final class DockMenuKeys: TapHandler {
    var isEnabled = false
    var isActive: Bool { isEnabled }
    let isOpen = Atomic<Bool>(false)
    var onEscape: () -> Void = {}

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, type == .keyDown || type == .keyUp, isOpen.load(ordering: .relaxed),
              event.getIntegerValueField(.keyboardEventKeycode) == kVK_Escape else { return event }
        if type == .keyDown { DispatchQueue.main.async { [onEscape] in onEscape() } }
        return nil
    }
}
