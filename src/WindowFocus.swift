import AppKit

// Goes to a window the switcher listed, wherever it is: shows its app if hidden, brings it back if minimized, and
// switches to its Space if it's on another. Shared by Alt-Tab and the Dock's window menu. Main thread.
enum WindowFocus {
    static func go(to target: SwitcherEntry) {
        if let app = NSRunningApplication(processIdentifier: target.pid), app.isHidden { app.unhide() }
        // AX.focus would bring the app forward on this Space; the window server switches to the window's own Space.
        if !target.isOnCurrentSpace, let id = target.windowID, SpaceWindows.canFocus {
            if target.isMinimized { AX.setMinimized(target.window, false) }
            if SpaceWindows.bringForward(id, pid: target.pid) {
                AX.raise(target.window)
                return
            }
        }
        AX.focus(target.window, pid: target.pid)
    }
}
