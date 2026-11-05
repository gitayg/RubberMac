import CoreGraphics

enum SnapSide { case left, right }

enum SnapDirection { case left, right, up, down }

enum SnapResult: Equatable {
    case frame(CGRect)
    case minimize
}

// The panes ⌘+arrows snap into on every screen: 2 × 2 gives halves and quarters, 3 × 2 thirds and sixths.
struct SnapGrid: Equatable {
    let columns: Int
    let rows: Int

    static let standard = SnapGrid(columns: 2, rows: 2)
}

// Screen rectangles in the Accessibility API's space: origin at the primary screen's top-left, y grows down.
// `blocked` is a spot windows keep clear of, like a camera standing in front of the screen.
struct ScreenArea {
    let frame: CGRect
    let visible: CGRect
    var blocked: CGRect? = nil
}

enum SnapGeometry {
    static let tolerance: CGFloat = 30

    // A full-height column (row nil) or one cell of it.
    private enum Slot {
        case full, pane(column: Int, row: Int?)
    }

    // Like Windows: ←/→ snap to a full-height column and step through the columns, keeping the row;
    // pressing toward the edge moves on to the neighbouring screen. From a column ↑/↓ go to the cell just
    // above or below the middle, then a row at a time; crossing the middle passes through the full column.
    // ↑ otherwise maximizes (leaving the menu bar and Dock visible); ↓ otherwise minimizes. Every pane keeps
    // clear of the screen's blocked spot.
    static func target(for window: CGRect, _ direction: SnapDirection, grid: SnapGrid = .standard,
                       screens: [ScreenArea]) -> SnapResult? {
        guard let current = screen(containing: window, in: screens) else { return nil }
        let slot = slot(of: window, in: current, grid)
        let upper = (grid.rows - 2) / 2
        let lower = grid.rows - 1 - upper
        switch direction {
        case .left, .right:
            let step = direction == .left ? -1 : 1
            guard case .pane(let column, let row) = slot else {
                return .frame(pane(current, grid, column: direction == .left ? 0 : grid.columns - 1, row: nil))
            }
            if (0..<grid.columns).contains(column + step) {
                return .frame(pane(current, grid, column: column + step, row: row))
            }
            guard let next = neighbour(of: current, side: direction == .left ? .left : .right, in: screens) else {
                return .frame(pane(current, grid, column: column, row: row))
            }
            return .frame(pane(next, grid, column: direction == .left ? grid.columns - 1 : 0, row: row))
        case .up:
            guard case .pane(let column, let row) = slot, grid.rows > 1 else { return .frame(full(current)) }
            guard let row else { return .frame(pane(current, grid, column: column, row: upper)) }
            if row == 0 { return .frame(full(current)) }
            if grid.rows % 2 == 0 && row == lower { return .frame(pane(current, grid, column: column, row: nil)) }
            return .frame(pane(current, grid, column: column, row: row - 1))
        case .down:
            guard case .pane(let column, let row) = slot, grid.rows > 1 else { return .minimize }
            guard let row else { return .frame(pane(current, grid, column: column, row: lower)) }
            if row == grid.rows - 1 { return .minimize }
            if grid.rows % 2 == 0 && row == upper { return .frame(pane(current, grid, column: column, row: nil)) }
            return .frame(pane(current, grid, column: column, row: row + 1))
        }
    }

    // Compared against the panes as they end up, blocked spot and all, so the next press steps on from there.
    private static func slot(of window: CGRect, in area: ScreenArea, _ grid: SnapGrid) -> Slot? {
        if isClose(window, full(area)) { return .full }
        for column in 0..<grid.columns {
            if isClose(window, pane(area, grid, column: column, row: nil)) { return .pane(column: column, row: nil) }
            for row in 0..<grid.rows where isClose(window, pane(area, grid, column: column, row: row)) {
                return .pane(column: column, row: row)
            }
        }
        return nil
    }

    private static func full(_ area: ScreenArea) -> CGRect { clear(area.visible, of: area.blocked) }

    static func pane(_ area: ScreenArea, _ grid: SnapGrid, column: Int, row: Int?) -> CGRect {
        clear(rect(area.visible, grid, column: column, row: row), of: area.blocked)
    }

    // The biggest part of `pane` beside, above or below the blocked spot. Beside is tried first, so a column
    // that loses as much either way keeps its full height. A pane the spot covers entirely is left as it is.
    static func clear(_ pane: CGRect, of blocked: CGRect?) -> CGRect {
        guard let blocked else { return pane }
        let hit = pane.intersection(blocked)
        guard !hit.isNull, hit.width > 0, hit.height > 0 else { return pane }
        let parts = [
            CGRect(x: pane.minX, y: pane.minY, width: hit.minX - pane.minX, height: pane.height),
            CGRect(x: hit.maxX, y: pane.minY, width: pane.maxX - hit.maxX, height: pane.height),
            CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: hit.minY - pane.minY),
            CGRect(x: pane.minX, y: hit.maxY, width: pane.width, height: pane.maxY - hit.maxY),
        ]
        let best = parts.max { $0.width * $0.height < $1.width * $1.height }!
        return best.width * best.height > 0 ? best : pane
    }

    static func rect(_ visible: CGRect, _ grid: SnapGrid, column: Int, row: Int?) -> CGRect {
        let x = edge(visible.minX, visible.width, column, grid.columns)
        let width = edge(visible.minX, visible.width, column + 1, grid.columns) - x
        guard let row else { return CGRect(x: x, y: visible.minY, width: width, height: visible.height) }
        let y = edge(visible.minY, visible.height, row, grid.rows)
        return CGRect(x: x, y: y, width: width, height: edge(visible.minY, visible.height, row + 1, grid.rows) - y)
    }

    // Pane borders on whole points, so neighbouring panes meet exactly and the last one ends at the screen edge.
    private static func edge(_ start: CGFloat, _ length: CGFloat, _ index: Int, _ count: Int) -> CGFloat {
        index == count ? start + length : start + (length * CGFloat(index) / CGFloat(count)).rounded(.down)
    }

    static func screen(containing window: CGRect, in screens: [ScreenArea]) -> ScreenArea? {
        let center = CGPoint(x: window.midX, y: window.midY)
        return screens.first { $0.frame.contains(center) }
            ?? screens.max { overlap($0.frame, window) < overlap($1.frame, window) }
    }

    static func neighbour(of current: ScreenArea, side: SnapSide, in screens: [ScreenArea]) -> ScreenArea? {
        let candidates = screens.filter {
            side == .left ? $0.frame.maxX <= current.frame.minX + 1 : $0.frame.minX >= current.frame.maxX - 1
        }
        return candidates.min { abs($0.frame.midX - current.frame.midX) < abs($1.frame.midX - current.frame.midX) }
    }

    // Apps like Terminal round their size to whole character cells, so allow some slack.
    static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }
}
