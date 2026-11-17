import CoreGraphics

// --selftest snap: where ⌘+arrows put a window on a 2 × 2 grid, and that ⌘↑ pressed again maximizes. Pure geometry
// on a made-up screen, so no window moves.
extension SnapGeometry {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        let screen = ScreenArea(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                visible: CGRect(x: 0, y: 25, width: 1920, height: 1055))
        let screens = [screen]
        let maximized = SnapResult.frame(screen.visible)
        let leftHalf = pane(screen, .standard, column: 0, row: nil)
        let rightHalf = pane(screen, .standard, column: 1, row: nil)
        let topLeft = pane(screen, .standard, column: 0, row: 0)
        let bottomLeft = pane(screen, .standard, column: 0, row: 1)
        let free = CGRect(x: 300, y: 300, width: 800, height: 600)
        // An app that can't be made as short as a quarter: after ⌘↑ from the half it is still nearly the half.
        let refused = CGRect(x: 0, y: 25, width: 960, height: 1040)
        func snap(_ window: CGRect, _ direction: SnapDirection, again: Bool = false) -> SnapResult? {
            target(for: window, direction, screens: screens, again: again)
        }

        // A first ⌘↑ steps through the panes.
        check(snap(free, .up) == maximized, "⌘↑ on a free window maximizes it")
        check(snap(leftHalf, .up) == .frame(topLeft), "⌘↑ on the left half goes to the top-left quarter")
        check(snap(bottomLeft, .up) == .frame(leftHalf), "⌘↑ on the bottom-left quarter goes to the left half")
        check(snap(topLeft, .up) == maximized, "⌘↑ on the top-left quarter maximizes it")
        check(snap(refused, .up) == .frame(topLeft), "⌘↑ on a window the size of the half asks for the top-left quarter")

        // ⌘↑ again.
        check(snap(leftHalf, .up, again: true) == maximized,
              "⌘↑ again, on the left half the bottom-left quarter went to, maximizes it (not the top-left quarter)")
        check(snap(topLeft, .up, again: true) == maximized, "⌘↑ again on the top-left quarter maximizes it")
        check(snap(refused, .up, again: true) == maximized, "⌘↑ again on an app that refused the quarter maximizes it")
        check(snap(screen.visible, .up, again: true) == maximized, "⌘↑ again on a maximized window leaves it maximized")
        check(snap(leftHalf, .down, again: true) == .frame(bottomLeft), "only ⌘↑ repeats: ⌘↓ on the left half still goes down")

        // With a camera in front of the screen (the spot marked on this Mac's TV): the first ⌘↑ keeps clear of it,
        // ⌘↑ again covers the whole screen.
        let camera = ScreenArea(frame: screen.frame, visible: CGRect(x: 0, y: 30, width: 1920, height: 1050),
                                blocked: CGRect(x: 749, y: 709, width: 219, height: 371))
        let clearOfCamera = SnapResult.frame(CGRect(x: 0, y: 30, width: 1920, height: 679))
        let cameraTopLeft = pane(camera, .standard, column: 0, row: 0)
        func snapCamera(_ window: CGRect, again: Bool = false) -> SnapResult? {
            target(for: window, .up, screens: [camera], again: again)
        }
        check(snapCamera(free) == clearOfCamera, "with the camera, ⌘↑ on a free window maximizes above the camera")
        check(snapCamera(CGRect(x: 0, y: 30, width: 1920, height: 679), again: true) == .frame(camera.visible),
              "with the camera, ⌘↑ again maximizes over the whole screen, camera spot too")
        check(snapCamera(cameraTopLeft, again: true) == .frame(camera.visible),
              "with the camera, ⌘↑ again on the top-left quarter maximizes over the whole screen")
        check(snapCamera(camera.visible, again: true) == .frame(camera.visible),
              "with the camera, ⌘↑ again on the whole-screen window leaves it there")

        // When a press counts as again.
        check(pressedAgain(topLeft, after: [topLeft]), "a window still where ⌘↑ put it counts as pressed again")
        check(pressedAgain(refused, after: [topLeft, refused]), "so does one still where the app put it instead")
        check(!pressedAgain(free, after: [topLeft, topLeft]), "a window moved since then doesn't")

        // The other arrows are unchanged.
        check(snap(leftHalf, .right) == .frame(rightHalf), "⌘→ on the left half goes to the right half")
        check(snap(topLeft, .down) == .frame(leftHalf), "⌘↓ on the top-left quarter goes to the left half")
        check(snap(bottomLeft, .down) == .minimize, "⌘↓ on the bottom-left quarter minimizes it")

        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
