import AppKit

// Mail's fonts: messages and the message list in Atkinson Hyperlegible Next, fixed-width text in Mono. Mail keeps them
// in its container, the list's font as an archived NSFont, and reads them as it starts, so they show once Mail is
// opened again. Sizes stay what Mail had.
struct MailFont: FontTarget {
    static let keys = ["NSFont", "NSFixedPitchFont", "MessageListFont"]
    static let defaultListSize: CGFloat = 13

    var id = "mail"
    let appName = "Mail"
    let bundleID = "com.apple.mail"
    var prefs = AppPrefs.sandboxed("com.apple.mail")

    var whatChanges: String {
        AppScript.isRunning(bundleID) ? "messages and the message list, once Mail is quit and opened again" : "messages and the message list"
    }

    var isOn: Bool {
        prefs.string("NSFont") == BundledFont.regular && prefs.string("NSFixedPitchFont") == BundledFont.monoRegular
            && ArchivedFont.name(in: prefs.value("MessageListFont") as? Data) == BundledFont.regular
    }

    func turnOn() throws {
        guard !isOn else { return }
        let listSize = ArchivedFont.size(in: prefs.value("MessageListFont") as? Data) ?? Self.defaultListSize
        guard let list = ArchivedFont.data(name: BundledFont.regular, size: listSize) else { throw ArchivedFont.Missing() }
        FontTargetMemory.remember(id, prefs.snapshot(Self.keys))
        try prefs.set(["NSFont": BundledFont.regular, "NSFixedPitchFont": BundledFont.monoRegular, "MessageListFont": list])
    }

    func turnOff() throws {
        try prefs.restore(Self.keys, from: FontTargetMemory.before(id) ?? [:])
        FontTargetMemory.forget(id)
    }
}
