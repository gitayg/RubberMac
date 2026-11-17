import AppKit
import ApplicationServices

// Which window the effect goes behind: the front app's focused window, if it's an ordinary window on the screen and not
// in full screen. RubberMAC's own windows never count, so while one of them is in front (the settings panel) the front
// app is the one that was in front before.
enum BackgroundDimFront {
    enum Target: Equatable {
        case below(CGWindowID)
        // Nothing has focus (the desktop, or an app with no window), or the window is in full screen.
        case none
    }

    struct Window: Equatable {
        var id: CGWindowID
        var layer: Int
        var onScreen: Bool
        var fullScreen = false
        var isSheet = false
    }

    // A hung app would otherwise hold up the main thread for the 6 s default.
    private static let timeout: Float = 0.25
    // Space type in SLSCopyManagedDisplaySpaces.
    private static let fullScreenType = 4

    // The target, and the window's Accessibility element so its closing can be watched. last is the app that was in front
    // before RubberMAC.
    static func current(ownPID: pid_t, last: pid_t) -> (target: Target, element: AXUIElement?) {
        guard let pid = frontApp(ownPID: ownPID, last: last) else { return (.none, nil) }
        let app = AX.app(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let focused = element(app, kAXFocusedWindowAttribute)
        var chosen = focused
        let target = target(focused: focused.flatMap(window),
                            parent: { chosen = focused.flatMap { element($0, kAXParentAttribute) }; return chosen.flatMap(window) },
                            main: { chosen = element(app, kAXMainWindowAttribute); return chosen.flatMap(window) })
        return (target, chosen)
    }

    // parent and main are read only when needed: the sheet's window, and the app's main window when a floating panel
    // of its own has the keyboard. The desktop, below every window, means nothing has focus.
    static func target(focused: Window?, parent: () -> Window?, main: () -> Window?) -> Target {
        var window = focused
        if window?.isSheet == true { window = parent() }
        if let layer = window?.layer, layer > 0 { window = main() }
        guard let window, window.layer == 0, window.onScreen, !window.fullScreen else { return .none }
        return .below(window.id)
    }

    static func frontApp(ownPID: pid_t, last: pid_t) -> pid_t? {
        frontApp(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier, ownPID: ownPID, last: last) {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])?
                .compactMap { window -> pid_t? in
                    guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
                    return (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                }.first { $0 != ownPID }
        }
    }

    // With RubberMAC in front and no app seen in front before it (just turned on from the settings panel), the app with
    // the topmost ordinary window.
    static func frontApp(frontmost: pid_t?, ownPID: pid_t, last: pid_t, topmost: () -> pid_t?) -> pid_t? {
        guard let frontmost else { return nil }
        guard frontmost == ownPID else { return frontmost }
        return last != 0 ? last : topmost()
    }

    // Displays showing a full-screen app's Space; they get no effect.
    static func fullScreenDisplays() -> Set<CGDirectDisplayID> {
        guard let connection, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let identifiers = fullScreenIdentifiers(displays)
        guard !identifiers.isEmpty else { return [] }
        return Set(NSScreen.screens.compactMap(\.displayID).filter { identifiers.contains(identifier(of: $0)) || identifiers.contains("Main") })
    }

    // "Main" stands for every display when they share their Spaces; otherwise each is its display's UUID.
    static func fullScreenIdentifiers(_ displays: [[String: Any]]) -> Set<String> {
        Set(displays.compactMap { display in
            guard let current = display["Current Space"] as? [String: Any],
                  (current["type"] as? NSNumber)?.intValue == fullScreenType else { return nil }
            return display["Display Identifier"] as? String
        })
    }

    static func identifier(of display: CGDirectDisplayID) -> String {
        CGDisplayCreateUUIDFromDisplayID(display).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
    }

    private static func window(_ element: AXUIElement) -> Window? {
        guard let id = AX.windowID(of: element),
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first else { return nil }
        return Window(id: id, layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                      onScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                      fullScreen: AX.bool(element, "AXFullScreen") == true,
                      isSheet: AX.string(element, kAXRoleAttribute) == kAXSheetRole)
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    // Private, as SpaceWindows uses it; looked up at run time so a missing symbol only loses the full-screen check.
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection: Int32? = dlsym(skyLight, "SLSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self)() }
    private static let copyManagedDisplaySpaces = dlsym(skyLight, "SLSCopyManagedDisplaySpaces")
        .map { unsafeBitCast($0, to: CopyManagedDisplaySpaces.self) }
}
