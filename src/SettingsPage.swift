import AppKit

// What the settings panel shows, as data: pages of cards of rows. AppDelegate.settingsPages() builds them afresh for
// each render; a row only describes itself, and SettingsRowView turns it into controls.
struct SettingsRow {
    enum Control {
        case none
        case toggle(on: Bool)
        case popup([NSMenuItem])
        case button(String, enabled: Bool)
        // A permission's state, with a button beside it when there's something to do.
        case status(String, isOn: Bool?, button: String?)
        case custom(NSView)
        case note
    }

    var title: String
    var note: String?
    var control: Control
    var target: AnyObject?
    var action: Selector?
    // For an action that takes over the screen, opens somewhere else or asks a question.
    var closesPanel = false

    static func note(_ text: String) -> SettingsRow {
        SettingsRow(title: text, note: nil, control: .note, target: nil, action: nil)
    }

    var isNote: Bool {
        if case .note = control { true } else { false }
    }

    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query) || note?.localizedCaseInsensitiveContains(query) == true
    }

    // Whether the other row is laid out the same, so the views can stay and just take its state.
    func hasSameShape(as other: SettingsRow) -> Bool {
        guard title == other.title, note == other.note else { return false }
        switch (control, other.control) {
        case (.none, .none), (.toggle, .toggle), (.custom, .custom), (.note, .note): return true
        case (.popup(let mine), .popup(let theirs)): return mine.map(\.title) == theirs.map(\.title)
        case (.button(let mine, _), .button(let theirs, _)): return mine == theirs
        case (.status(let a, let b, let c), .status(let d, let e, let f)): return a == d && b == e && c == f
        default: return false
        }
    }
}

struct SettingsSection {
    var title: String?
    var rows: [SettingsRow]
}

struct SettingsPage {
    var id: String
    var title: String
    var symbol: String
    var tint: NSColor
    var sections: [SettingsSection]
    var needsAttention = false

    var rows: [SettingsRow] { sections.flatMap(\.rows) }

    // Only the rows that match, in cards that still have any; nil when none do. Blank text matches everything.
    func filtered(_ query: String) -> SettingsPage? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return self }
        var page = self
        page.sections = sections.compactMap { section in
            let rows = section.rows.filter { $0.matches(text) }
            return rows.isEmpty ? nil : SettingsSection(title: section.title, rows: rows)
        }
        return page.sections.isEmpty ? nil : page
    }

    func hasSameShape(as other: SettingsPage) -> Bool {
        guard id == other.id, sections.map(\.title) == other.sections.map(\.title), rows.count == other.rows.count else { return false }
        return zip(sections, other.sections).allSatisfy { $0.rows.count == $1.rows.count }
            && zip(rows, other.rows).allSatisfy { $0.hasSameShape(as: $1) }
    }
}
