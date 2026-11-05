import AppKit

enum WindowSnapper {
    static func snap(_ direction: SnapDirection, grid: SnapGrid) {
        guard AX.isTrusted else { AX.requestAccess(); return }
        guard let window = frontWindow(),
              let current = AX.frame(of: window),
              let result = SnapGeometry.target(for: current, direction, grid: grid, screens: screenAreas()) else { return }
        switch result {
        case .frame(let target): AX.setFrame(window, target)
        case .minimize: AX.setMinimized(window, true)
        }
    }

    // NSScreen is bottom-left-origin; flip into the Accessibility API's top-left-origin space. With the camera
    // toggle on, the screen the camera stands in front of gets its spot as `blocked`.
    static func screenAreas() -> [ScreenArea] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        func flip(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
        let camera = Settings.cameraAvoid ? Settings.cameraArea : nil
        return NSScreen.screens.map { screen in
            let blocked = camera.flatMap { $0.display == screen.displayID.map(CameraArea.key) ? flip($0.box(on: screen.frame)) : nil }
            return ScreenArea(frame: flip(screen.frame), visible: flip(screen.visibleFrame), blocked: blocked)
        }
    }

    static func screen(of camera: CameraArea) -> NSScreen? {
        NSScreen.screens.first { $0.displayID.map(CameraArea.key) == camera.display }
    }

    // Where the camera spot lands and where ⌘↑, ⌘← and ⌘→ would put a window on that screen. Moves nothing.
    static func cameraSelfTestReport() -> String {
        guard let camera = Settings.cameraArea else { return "camera: not marked" }
        let areas = screenAreas()
        var lines = ["camera: marked on \(camera.name) (\(camera.display)), toggle \(Settings.cameraAvoid ? "on" : "off")"]
        for (screen, area) in zip(NSScreen.screens, areas) {
            lines.append("\(screen.localizedName): frame \(area.frame), visible \(area.visible), blocked \(area.blocked.map { "\($0)" } ?? "none")")
            guard area.blocked != nil else { continue }
            let window = CGRect(x: area.visible.midX - 200, y: area.visible.minY + 50, width: 400, height: 300)
            for direction in [SnapDirection.up, .left, .right] {
                lines.append("  ⌘\(direction): \(SnapGeometry.target(for: window, direction, screens: areas).map { "\($0)" } ?? "nil")")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func frontWindow() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return AX.focusedWindow(of: pid)
    }
}
