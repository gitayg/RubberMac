import AppKit
import CoreText

// Atkinson Hyperlegible Next and its monospaced sibling Atkinson Hyperlegible Mono, the Braille Institute's typefaces
// for easy reading, ship inside the app under the SIL Open Font License (THIRD_PARTY_NOTICES.md), a folder per family.
// Turning them on copies their 28 faces into ~/Library/Fonts, as Font Book's Install does, and every app's font list has
// them; turning them off removes only files that are still RubberMAC's own, byte for byte. macOS's own interface font
// can't be changed: it's on the sealed system volume.
enum BundledFont {
    static let name = "Atkinson Hyperlegible"
    static let family = "Atkinson Hyperlegible Next"
    static let monoFamily = "Atkinson Hyperlegible Mono"
    static let families = [family, monoFamily]
    static let regular = "AtkinsonHyperlegibleNext-Regular"
    static let monoRegular = "AtkinsonHyperlegibleMono-Regular"
    static let userFonts = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts")

    struct Outcome: Equatable {
        var copied = 0
        var removed = 0
        // Files under one of the faces' names that aren't RubberMAC's copy, so they're neither overwritten nor removed.
        var leftAlone: [String] = []
    }

    static func faces(in resources: URL? = Bundle.main.resourceURL) -> [URL] {
        guard let folder = resources?.appendingPathComponent("Fonts") else { return [] }
        let families = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return families.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "otf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // The faces of one family, by file name: AtkinsonHyperlegibleMono-Bold.otf is Mono's.
    static func faces(of family: String, _ all: [URL] = faces()) -> [URL] {
        let prefix = family.replacingOccurrences(of: " ", with: "") + "-"
        return all.filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    // Apps can use both families: their regular faces load, from RubberMAC's copies or from anywhere else.
    static var isAvailable: Bool { NSFont(name: regular, size: 12) != nil && NSFont(name: monoRegular, size: 12) != nil }

    // Every face is in the folder, unchanged.
    static func isInstalled(_ faces: [URL] = faces(), in folder: URL = userFonts) -> Bool {
        !faces.isEmpty && faces.allSatisfy { same($0, folder.appendingPathComponent($0.lastPathComponent)) }
    }

    // The families' font files macOS has from somewhere other than RubberMAC's copies, like a download from Google Fonts.
    static func elsewhere(_ faces: [URL] = faces(), in folder: URL = userFonts) -> [URL] {
        let ours = Set(faces.map { folder.appendingPathComponent($0.lastPathComponent).standardizedFileURL.path })
        return families.flatMap { family -> [URL] in
            let wanted = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
            let matches = CTFontDescriptorCreateMatchingFontDescriptors(wanted, nil) as? [CTFontDescriptor] ?? []
            return matches.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontURLAttribute) as? URL }
        }.filter { !ours.contains($0.standardizedFileURL.path) }
    }

    // Turned on before the app carried Mono: every Next face is RubberMAC's copy and Mono is missing, so Mono is added
    // to match. Anything else is left as it is.
    @discardableResult
    static func completeEarlierInstall(_ faces: [URL] = faces(), in folder: URL = userFonts) throws -> Outcome? {
        let next = Self.faces(of: family, faces), mono = Self.faces(of: monoFamily, faces)
        guard !mono.isEmpty, isInstalled(next, in: folder),
              !mono.contains(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.lastPathComponent).path) })
        else { return nil }
        return try install(mono, into: folder)
    }

    // Copies the faces that are missing, as new files with none of the app's extended attributes.
    @discardableResult
    static func install(_ faces: [URL] = faces(), into folder: URL = userFonts) throws -> Outcome {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var outcome = Outcome()
        for face in faces {
            let target = folder.appendingPathComponent(face.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                if !same(face, target) { outcome.leftAlone.append(face.lastPathComponent) }
                continue
            }
            try Data(contentsOf: face).write(to: target, options: .withoutOverwriting)
            outcome.copied += 1
        }
        return outcome
    }

    @discardableResult
    static func remove(_ faces: [URL] = faces(), from folder: URL = userFonts) throws -> Outcome {
        var outcome = Outcome()
        for face in faces {
            let target = folder.appendingPathComponent(face.lastPathComponent)
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            guard same(face, target) else {
                outcome.leftAlone.append(face.lastPathComponent)
                continue
            }
            try FileManager.default.removeItem(at: target)
            outcome.removed += 1
        }
        return outcome
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? Data(contentsOf: a), let y = try? Data(contentsOf: b) else { return false }
        return x == y
    }
}
