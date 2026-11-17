import CoreGraphics

// When a window counts as lost, and where it goes back to. Frames in the Accessibility API's space, as ScreenArea's.
// Lost is mostly off every screen (under a third of it showing, or its title bar out of reach) or bigger than the
// visible area of the screen it's on. A lost window goes onto the screen holding most of it, else the main screen,
// clear of the camera when that's on, keeping its size if it fits there and moved only as far as it must be.
enum WindowResetGeometry {
    enum Problem: Equatable {
        case offScreen, tooBig
    }

    static let showingShare: CGFloat = 1.0 / 3
    // The title bar's middle, below the window's top edge, and how much of it must be on a screen to drag it by.
    static let titleBarMiddle: CGFloat = 12
    static let grabWidth: CGFloat = 40
    // Apps size windows to fractions of a point; a maximized one may come out a point over.
    static let slack: CGFloat = 2

    static func problem(_ window: CGRect, screens: [ScreenArea]) -> Problem? {
        guard !screens.isEmpty else { return nil }
        let showing = screens.reduce(0) { $0 + area($1.visible.intersection(window)) }
        if showing < area(window) * showingShare || !titleBarReachable(window, screens) { return .offScreen }
        let visible = home(of: window, screens).visible
        if window.width > visible.width + slack || window.height > visible.height + slack { return .tooBig }
        return nil
    }

    // Nil for a window that's fine, which is never touched.
    static func fixed(_ window: CGRect, screens: [ScreenArea]) -> CGRect? {
        guard problem(window, screens: screens) != nil else { return nil }
        let home = home(of: window, screens)
        let room = SnapGeometry.clear(home.visible, of: home.blocked)
        let width = min(window.width, room.width), height = min(window.height, room.height)
        return CGRect(x: min(max(window.minX, room.minX), room.maxX - width),
                      y: min(max(window.minY, room.minY), room.maxY - height), width: width, height: height)
    }

    // The screen holding most of the window; for one on no screen at all, the main screen.
    static func home(of window: CGRect, _ screens: [ScreenArea]) -> ScreenArea {
        let most = screens.max { area($0.frame.intersection(window)) < area($1.frame.intersection(window)) }!
        return area(most.frame.intersection(window)) > 0 ? most : screens[0]
    }

    // Under the menu bar, past a screen's edge or behind the Dock, a title bar can't be grabbed to drag the window back.
    static func titleBarReachable(_ window: CGRect, _ screens: [ScreenArea]) -> Bool {
        let y = window.minY + min(titleBarMiddle, window.height / 2)
        let needed = min(grabWidth, window.width)
        return screens.contains { screen in
            screen.visible.minY <= y && y < screen.visible.maxY
                && min(window.maxX, screen.visible.maxX) - max(window.minX, screen.visible.minX) >= needed
        }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
