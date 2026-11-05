import AppKit
import ApplicationServices

// The Finder window the strip goes on, read with Accessibility on the main thread, so each read has a short timeout:
// a hung Finder would otherwise block it for the 6 s default.
struct FinderBrowserWindow {
    static let timeout: Float = 0.25

    let element: AXUIElement
    let id: CGWindowID
    // In Accessibility coordinates (origin at the top left of the primary screen).
    let frame: CGRect
    // How far below the window's top the strip starts.
    let top: CGFloat
    let hasToolbar: Bool
    let hasTabBar: Bool

    // Finder's focused window, when it's a folder window showing on this Space: not the desktop, Get Info, a dialog,
    // or a window that's minimized or on another Space.
    static func focused(in pid: pid_t) -> FinderBrowserWindow? {
        let app = AX.app(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, timeout)
        guard let list = values(window, [kAXSubroleAttribute, kAXMinimizedAttribute, kAXPositionAttribute,
                                         kAXSizeAttribute, kAXChildrenAttribute]),
              list[0] as? String == kAXStandardWindowSubrole, (list[1] as? NSNumber)?.boolValue != true,
              let frame = frame(list[2], list[3]), let id = AX.windowID(of: window), isOnScreen(id) else { return nil }

        var toolbar: CGRect?, tabGroups: [CGRect] = [], hasSplit = false
        for child in (list[4] as? [AXUIElement]) ?? [] {
            AXUIElementSetMessagingTimeout(child, timeout)
            // A child that doesn't answer in time means Finder is busy; don't wait on the rest as well.
            guard let parts = values(child, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute]) else { break }
            switch parts[0] as? String {
            case kAXToolbarRole: toolbar = toolbar ?? self.frame(parts[1], parts[2])
            case kAXTabGroupRole: if let tabs = self.frame(parts[1], parts[2]) { tabGroups.append(tabs) }
            case kAXSplitGroupRole: hasSplit = true
            default: break
            }
        }
        // Get Info and progress windows are standard windows too, but have neither a toolbar nor a sidebar split.
        guard toolbar != nil || hasSplit else { return nil }
        return FinderBrowserWindow(element: window, id: id, frame: frame,
                                   top: FinderAddressBarLayout.top(window: frame, toolbar: toolbar, tabGroups: tabGroups),
                                   hasToolbar: toolbar != nil,
                                   hasTabBar: FinderAddressBarLayout.tabBar(window: frame, toolbar: toolbar, tabGroups: tabGroups) != nil)
    }

    // Where the window is now, for following a move without reading the rest again.
    func moved() -> FinderBrowserWindow? {
        guard let list = Self.values(element, [kAXPositionAttribute, kAXSizeAttribute]),
              let frame = Self.frame(list[0], list[1]) else { return nil }
        return FinderBrowserWindow(element: element, id: id, frame: frame, top: top, hasToolbar: hasToolbar, hasTabBar: hasTabBar)
    }

    // Shown on the current Space, and not minimized or hidden.
    static func isOnScreen(_ id: CGWindowID) -> Bool {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
        return info?.first?[kCGWindowIsOnscreen as String] as? Bool == true
    }

    // One round trip for all the attributes; a failed one comes back as an AXError value, not the type asked for.
    private static func values(_ element: AXUIElement, _ names: [String]) -> [AnyObject]? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
              let list = values as? [AnyObject], list.count == names.count else { return nil }
        return list
    }

    private static func frame(_ position: AnyObject, _ size: AnyObject) -> CGRect? {
        var origin = CGPoint.zero, extent = CGSize.zero
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
