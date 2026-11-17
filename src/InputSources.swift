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

    // Returns the source in use afterwards: the one asked for, unless it's no longer enabled.
    @discardableResult
    static func select(_ wanted: String) -> String {
        if let source = keyboards().first(where: { id($0) == wanted }) { TISSelectInputSource(source) }
        return currentID()
    }

    // An English layout for search: ABC, U.S., British and the like, the one used last if it's enabled.
    static func english() -> String? {
        let layouts = keyboards().filter(isEnglishLayout).map(id)
        let recent = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().map { id($0.takeRetainedValue()) }
        return pickEnglish(layouts: layouts, recent: recent)
    }

    static func pickEnglish(layouts: [String], recent: String?) -> String? {
        if let recent, layouts.contains(recent) { return recent }
        return layouts.first
    }

    // A plain keyboard layout that types Latin letters, not an input method like Pinyin or Kotoeri.
    static func isEnglishLayout(_ source: TISInputSource) -> Bool {
        guard let ascii = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable),
              let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ascii).takeUnretainedValue())
            && Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String == kTISTypeKeyboardLayout as String
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
