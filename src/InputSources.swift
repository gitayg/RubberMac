import Carbon

// The keyboard languages enabled in System Settings › Keyboard › Input Sources.
enum InputSources {
    static func keyboards() -> [TISInputSource] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
            kTISPropertyInputSourceIsEnabled as String: true,
        ] as CFDictionary
        return TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    static func id(_ source: TISInputSource) -> String {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    static func currentID() -> String {
        id(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }

    // Next in the list, wrapping around, like Windows' Alt+Shift.
    static func selectNext() {
        let sources = keyboards()
        guard sources.count > 1 else { return }
        let now = currentID()
        let index = sources.firstIndex { id($0) == now } ?? -1
        let next = sources[(index + 1) % sources.count]
        TISSelectInputSource(next)
        log("input source: \(now) -> \(id(next))")
    }

    // Switches forward and back again, reading the result after each step.
    static func selfTestReport() -> String {
        let start = currentID()
        var lines = ["enabled: \(keyboards().map(id).joined(separator: ", "))", "current: \(start)"]
        selectNext()
        lines.append("after switch: \(currentID())")
        while currentID() != start, lines.count < 10 {
            selectNext()
            lines.append("after switch: \(currentID())")
        }
        return lines.joined(separator: "\n")
    }
}
