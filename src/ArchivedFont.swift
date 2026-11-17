import AppKit

// An NSFont as apps archive it in their settings (Mail's message list, Terminal's profiles). Reading takes just the
// name and size out of the archive, without making the font: one only that app has, like Terminal's SF Mono, wouldn't
// load here.
enum ArchivedFont {
    struct Missing: Error {}

    static func data(name: String, size: CGFloat) -> Data? {
        guard let font = NSFont(name: name, size: size) else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: font, requiringSecureCoding: true)
    }

    static func name(in data: Data?) -> String? { fields(in: data)?.name }
    static func size(in data: Data?) -> CGFloat? { fields(in: data)?.size }

    private static func fields(in data: Data?) -> FontFields? {
        guard let data, let reader = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        reader.requiresSecureCoding = false
        reader.setClass(FontFields.self, forClassName: "NSFont")
        defer { reader.finishDecoding() }
        return reader.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? FontFields
    }
}

@objc(RubberMACFontFields) private final class FontFields: NSObject, NSCoding {
    let name: String?
    let size: CGFloat?

    init?(coder: NSCoder) {
        name = coder.decodeObject(forKey: "NSName") as? String
        size = coder.containsValue(forKey: "NSSize") ? CGFloat(coder.decodeDouble(forKey: "NSSize")) : nil
    }

    func encode(with coder: NSCoder) {}
}
