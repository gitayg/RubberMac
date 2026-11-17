import CoreGraphics

// The screens as the pointer guard sees them, in global coordinates (top-left of the main screen, y grows down).
struct DockScreenLayout: Equatable {
    var screens: [CGRect]
    // The screen the Dock is kept on.
    var chosen: Int
    // Where the Dock is now, if not on the chosen screen: its edge is left alone too, so a Dock that couldn't be
    // brought over can still be reached.
    var dockAt: Int?
    // How many rows (or columns) of points at another screen's Dock edge the pointer is kept out of.
    var depth: CGFloat = 1

    func isFree(_ index: Int) -> Bool { index == chosen || index == dockAt }
}

// Pure geometry, so the self-test can run it on made-up screens. macOS moves the Dock to a screen when the pointer,
// already on the last row (or column) of points at that screen's Dock edge, keeps being pushed past it. Only an
// outer edge can be pushed against: one that runs into another screen is crossed instead.
enum DockScreenGeometry {
    typealias Edge = FullScreenDock.Edge

    // Exact first; a point on the far border (y == maxY) still counts for the screen it borders.
    static func screen(at point: CGPoint, in screens: [CGRect]) -> Int? {
        screens.firstIndex { $0.contains(point) } ?? screens.firstIndex { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }

    // Within `depth` rows of points of an outer edge.
    static func isAgainst(_ edge: Edge, _ point: CGPoint, of screen: CGRect, _ screens: [CGRect], depth: CGFloat = 1) -> Bool {
        let beyond: CGPoint
        switch edge {
        case .bottom:
            guard point.y >= screen.maxY - depth else { return false }
            beyond = CGPoint(x: point.x, y: screen.maxY)
        case .left:
            guard point.x < screen.minX + depth else { return false }
            beyond = CGPoint(x: screen.minX - 0.5, y: point.y)
        case .right:
            guard point.x >= screen.maxX - depth else { return false }
            beyond = CGPoint(x: screen.maxX, y: point.y)
        }
        return !screens.contains { $0.contains(beyond) }
    }

    // Within `depth` points of the bottom, left or right of its screen: the only places held() can act, checked first
    // so most moves cost nothing more.
    static func nearSomeEdge(_ point: CGPoint, of screen: CGRect, depth: CGFloat) -> Bool {
        point.y >= screen.maxY - depth || point.x < screen.minX + depth || point.x >= screen.maxX - depth
    }

    // For a move into the band at another screen's Dock edge: the same move just short of the band and without the
    // part that pushes toward the edge, so the pointer neither reaches the edge nor pushes. Along the edge and away
    // from it, it goes on as it was. nil leaves the move alone.
    static func held(_ point: CGPoint, delta: CGVector, edge: Edge, layout: DockScreenLayout) -> (point: CGPoint, delta: CGVector)? {
        guard let index = screen(at: point, in: layout.screens), !layout.isFree(index) else { return nil }
        let screen = layout.screens[index]
        let depth = layout.depth
        guard isAgainst(edge, point, of: screen, layout.screens, depth: depth) else { return nil }
        switch edge {
        case .bottom: return (CGPoint(x: point.x, y: screen.maxY - depth - 1), CGVector(dx: delta.dx, dy: min(delta.dy, 0)))
        case .left: return (CGPoint(x: screen.minX + depth, y: point.y), CGVector(dx: max(delta.dx, 0), dy: delta.dy))
        case .right: return (CGPoint(x: screen.maxX - depth - 1, y: point.y), CGVector(dx: min(delta.dx, 0), dy: delta.dy))
        }
    }

    // The screen the Dock's strip of icons belongs to: the one whose Dock edge it sits against, inside it while shown
    // or just past it while hidden (on macOS 27 its near side is right on the edge then). nil when it's against none.
    static func dockScreen(strip: CGRect, edge: Edge, screens: [CGRect]) -> Int? {
        let thickness = edge == .bottom ? strip.height : strip.width
        let gaps: [(Int, CGFloat)] = screens.enumerated().compactMap { index, screen in
            switch edge {
            case .bottom:
                guard strip.midX >= screen.minX, strip.midX < screen.maxX else { return nil }
                return (index, min(abs(strip.maxY - screen.maxY), abs(strip.minY - screen.maxY)))
            case .left:
                guard strip.midY >= screen.minY, strip.midY < screen.maxY else { return nil }
                return (index, min(abs(strip.minX - screen.minX), abs(strip.maxX - screen.minX)))
            case .right:
                guard strip.midY >= screen.minY, strip.midY < screen.maxY else { return nil }
                return (index, min(abs(strip.minX - screen.maxX), abs(strip.maxX - screen.maxX)))
            }
        }
        return gaps.filter { $0.1 <= max(thickness / 2, 8) }.min { $0.1 < $1.1 }?.0
    }

    // Where to push to bring the Dock to a screen: on its Dock edge where nothing lies beyond, as near the middle as
    // there is such a place; nil if the whole edge runs into other screens.
    static func pushPoint(on index: Int, edge: Edge, screens: [CGRect]) -> CGPoint? {
        let screen = screens[index]
        let steps = 64
        let fractions = (0...steps).map { CGFloat($0) / CGFloat(steps) }.sorted { abs($0 - 0.5) < abs($1 - 0.5) }
        for f in fractions {
            let point: CGPoint
            switch edge {
            case .bottom: point = CGPoint(x: (screen.minX + f * (screen.width - 1)).rounded(.down), y: screen.maxY - 1)
            case .left: point = CGPoint(x: screen.minX, y: (screen.minY + f * (screen.height - 1)).rounded(.down))
            case .right: point = CGPoint(x: screen.maxX - 1, y: (screen.minY + f * (screen.height - 1)).rounded(.down))
            }
            if isAgainst(edge, point, of: screen, screens) { return point }
        }
        return nil
    }

    // A push as macOS reads one: a move that keeps going past the edge while the pointer stays on it.
    static func pushDelta(_ edge: Edge, _ distance: CGFloat) -> CGVector {
        switch edge {
        case .bottom: return CGVector(dx: 0, dy: distance)
        case .left: return CGVector(dx: -distance, dy: 0)
        case .right: return CGVector(dx: distance, dy: 0)
        }
    }
}
