import AppKit
import IOKit.graphics

// A screen's modes as the popup lists them. Only modes macOS calls usable for the desktop are listed, plus the one in
// use whatever it is; modes alike in pixels, size and refresh rate are listed once (macOS lists some twice when asked
// for the low-resolution ones too). Grouped by the pixels sent, most first; in a group the plain mode comes before
// the HiDPI ones, then the fastest refresh first. A HiDPI mode drawn at more pixels than the screen has doesn't send
// those pixels, so it says what it's drawn at instead and goes in a last group of its own.
extension ScreenResolution {
    struct Mode: Equatable {
        let id: Int32
        let pixelWidth: Int
        let pixelHeight: Int
        let width: Int
        let height: Int
        let refresh: Double
        var usable = true
        // macOS's mark for the screen's own resolution.
        var native = false

        var isHiDPI: Bool { pixelWidth > width || pixelHeight > height }

        // The same mode on a screen that came back, whose modes may be numbered anew.
        func sameMode(as other: Mode) -> Bool {
            pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight && width == other.width && height == other.height
                && Self.rate(refresh) == Self.rate(other.refresh)
        }

        // Refresh rates to the hundredth, as macOS reports 59.94 as 59.94005994.
        static func rate(_ refresh: Double) -> Int { Int((refresh * 100).rounded()) }
    }

    struct Entry: Equatable {
        let mode: Mode
        let title: String
        let current: Bool
        let native: Bool
    }

    // What a screen offers and what it's using.
    struct Reading {
        var modes: [Mode]
        var current: Mode?
    }

    static func menu(_ modes: [Mode], current: Mode?) -> [[Entry]] {
        var candidates = modes.filter { $0.usable || $0 == current }
        if let current, !modes.contains(current) { candidates.append(current) }
        // The one in use stands for its look-alikes, otherwise the first macOS lists.
        var listed: [Mode] = []
        for mode in candidates.filter({ $0 == current }) + candidates.filter({ $0 != current })
        where !listed.contains(where: { $0.sameMode(as: mode) }) {
            listed.append(mode)
        }
        let context = Context(listed, all: modes)

        let (scaled, sent) = (listed.filter(context.drawnLarger), listed.filter { !context.drawnLarger($0) })
        let sizes = Dictionary(grouping: sent) { Size(width: $0.pixelWidth, height: $0.pixelHeight) }
        var groups = sizes.keys.sorted { ($0.width * $0.height, $0.width) > ($1.width * $1.height, $1.width) }.map { size in
            sizes[size]!.sorted { a, b in
                (a.isHiDPI ? 0 : 1, a.width * a.height, Mode.rate(a.refresh)) > (b.isHiDPI ? 0 : 1, b.width * b.height, Mode.rate(b.refresh))
            }
        }
        if !scaled.isEmpty {
            groups.append(scaled.sorted { ($0.width * $0.height, Mode.rate($0.refresh)) > ($1.width * $1.height, Mode.rate($1.refresh)) })
        }
        return groups.map { group in
            group.map { Entry(mode: $0, title: context.title($0), current: $0 == current, native: context.isNative($0)) }
        }
    }

    // The title a mode has in the menu, for the question after choosing it.
    static func title(of mode: Mode, among modes: [Mode]) -> String {
        menu(modes, current: mode).joined().first { $0.current }!.title
    }

    private struct Size: Hashable {
        let width: Int
        let height: Int
    }

    // What the titles depend on besides the mode itself: the screen's own resolution, and whether it offers more than
    // one refresh rate (a rate of 0 is a screen that doesn't say).
    private struct Context {
        let native: Size?
        let marked: Bool
        let showsRate: Bool

        init(_ listed: [Mode], all: [Mode]) {
            let flagged = all.filter(\.native).map { Size(width: $0.pixelWidth, height: $0.pixelHeight) }
            // Without macOS's mark, the most pixels a plain mode sends.
            let plain = listed.filter { !$0.isHiDPI }.map { Size(width: $0.pixelWidth, height: $0.pixelHeight) }
            native = (flagged.isEmpty ? plain : flagged).max { $0.width * $0.height < $1.width * $1.height }
            marked = !flagged.isEmpty
            showsRate = Set(listed.map { Mode.rate($0.refresh) }.filter { $0 > 0 }).count > 1
        }

        func isNative(_ mode: Mode) -> Bool { native == Size(width: mode.pixelWidth, height: mode.pixelHeight) }

        // Only against macOS's own mark: a guessed size could take the screen's real resolution for a larger drawing.
        func drawnLarger(_ mode: Mode) -> Bool {
            guard marked, let native, mode.isHiDPI else { return false }
            return mode.pixelWidth > native.width || mode.pixelHeight > native.height
        }

        func title(_ mode: Mode) -> String {
            let rate = showsRate && mode.refresh > 0 ? ", \(ScreenResolution.hertz(mode.refresh))" : ""
            if drawnLarger(mode) {
                return "Looks like \(mode.width) × \(mode.height), drawn at \(mode.pixelWidth) × \(mode.pixelHeight)\(rate)"
            }
            let looks = mode.isHiDPI ? ", looks like \(mode.width) × \(mode.height)" : ""
            return "\(mode.pixelWidth) × \(mode.pixelHeight)\(looks)\(rate)\(isNative(mode) ? " (native)" : "")"
        }
    }

    static func hertz(_ refresh: Double) -> String {
        let hundredths = Mode.rate(refresh)
        if hundredths % 100 == 0 { return "\(hundredths / 100) Hz" }
        return String(format: hundredths % 10 == 0 ? "%.1f Hz" : "%.2f Hz", Double(hundredths) / 100)
    }

    // MARK: Reading Quartz

    static let listOptions = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary

    static func displayModes(of display: CGDirectDisplayID) -> [CGDisplayMode] {
        CGDisplayCopyAllDisplayModes(display, listOptions) as? [CGDisplayMode] ?? []
    }

    static func reading(_ display: CGDirectDisplayID) -> Reading {
        Reading(modes: displayModes(of: display).map(Mode.init), current: CGDisplayCopyDisplayMode(display).map(Mode.init))
    }
}

extension ScreenResolution.Mode {
    init(_ mode: CGDisplayMode) {
        self.init(id: mode.ioDisplayModeID, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, width: mode.width,
                  height: mode.height, refresh: mode.refreshRate, usable: mode.isUsableForDesktopGUI(),
                  native: Int(mode.ioFlags) & kDisplayModeNativeFlag != 0)
    }
}
