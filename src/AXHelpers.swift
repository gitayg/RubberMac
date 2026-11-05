import AppKit
import ApplicationServices

// Thin wrappers over the Accessibility API, shared by snapping, the window switcher and layouts.
// Frames are in the Accessibility space: origin at the primary screen's top-left, y grows down.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    // Windows on the current Space (and minimized ones, and all of a hidden app's), in the app's own order.
    static func windows(of pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid), kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid), kAXFocusedWindowAttribute as CFString, &value) == .success else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let p = axValue(window, kAXPositionAttribute), AXValueGetValue(p, .cgPoint, &origin),
              let s = axValue(window, kAXSizeAttribute), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // Size, move, size again: a window can't be moved partly off a screen, and the
    // first resize may be clamped by the screen it is leaving.
    static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        setSize(window, frame.size)
        setOrigin(window, frame.origin)
        setSize(window, frame.size)
    }

    static func setMinimized(_ window: AXUIElement, _ minimized: Bool) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    // Brings one window to the front: unminimize, raise, then make its app frontmost.
    static func focus(_ window: AXUIElement, pid: pid_t) {
        if bool(window, kAXMinimizedAttribute) == true { setMinimized(window, false) }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    // Raises one window and makes it its app's main window, leaving which app is frontmost alone.
    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    // The CGWindowID behind an AX window (private but long-standing; used by AltTab and Rectangle).
    static func windowID(of window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as! AXValue)
    }

    private static func setOrigin(_ window: AXUIElement, _ origin: CGPoint) {
        var origin = origin
        if let v = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        }
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var size = size
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
        }
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
