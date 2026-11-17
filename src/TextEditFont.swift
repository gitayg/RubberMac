import Foundation

// TextEdit's fonts for new documents: Atkinson Hyperlegible Next for rich text, Mono for plain text. These are the
// AppKit user-font keys in TextEdit's container, which TextEdit reads as it starts, so it shows once TextEdit is opened
// again. Sizes stay what TextEdit had.
struct TextEditFont: FontTarget {
    static let keys = ["NSFont", "NSFixedPitchFont"]

    var id = "textedit"
    let appName = "TextEdit"
    let bundleID = "com.apple.TextEdit"
    var prefs = AppPrefs.sandboxed("com.apple.TextEdit")

    var whatChanges: String {
        AppScript.isRunning(bundleID) ? "new documents, once TextEdit is quit and opened again" : "new documents"
    }

    var isOn: Bool {
        prefs.string("NSFont") == BundledFont.regular && prefs.string("NSFixedPitchFont") == BundledFont.monoRegular
    }

    func turnOn() throws {
        guard !isOn else { return }
        FontTargetMemory.remember(id, prefs.snapshot(Self.keys))
        try prefs.set(["NSFont": BundledFont.regular, "NSFixedPitchFont": BundledFont.monoRegular])
    }

    func turnOff() throws {
        try prefs.restore(Self.keys, from: FontTargetMemory.before(id) ?? [:])
        FontTargetMemory.forget(id)
    }
}
