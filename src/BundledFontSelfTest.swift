import CoreText
import Foundation

extension BundledFont {
    /// --selftest fonts: the app carries the 14 faces and their licence, and turning the font on and off works on a
    /// scratch folder: it copies what's missing, overwrites and removes nothing that isn't RubberMAC's, and leaves
    /// ~/Library/Fonts alone. The real install is checked by turning it on and finding the family in another app.
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func finish() -> String { (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n") }

        let faces = faces()
        check(faces.count == 14, "the app carries \(faces.count) faces of \(family) (14 expected)")
        let licence = Bundle.main.resourceURL?.appendingPathComponent("Fonts/OFL.txt")
        check(licence.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("SIL OPEN FONT LICENSE Version 1.1") == true,
              "and their licence, OFL.txt")
        let fonts = faces.flatMap { CTFontManagerCreateFontDescriptorsFromURL($0 as CFURL) as? [CTFontDescriptor] ?? [] }
            .map { CTFontCreateWithFontDescriptor($0, 12, nil) }
        check(fonts.count == faces.count && fonts.allSatisfy { CTFontCopyFamilyName($0) as String == family },
              "each file is one font of the family")
        check(fonts.allSatisfy { (CTFontCopyName($0, kCTFontLicenseNameKey) as String?)?.contains("SIL Open Font License") == true },
              "each font carries its licence notice")
        let styles = Set(fonts.compactMap { CTFontCopyName($0, kCTFontStyleNameKey) as String? })
        check(styles.isSuperset(of: ["Regular", "Italic", "Bold", "Bold Italic", "ExtraLight", "ExtraBold"]),
              "the styles run from ExtraLight to ExtraBold, each with an italic: \(styles.sorted().joined(separator: ", "))")
        guard faces.count > 2 else { return finish() }

        let realBefore = (try? FileManager.default.contentsOfDirectory(atPath: userFonts.path).sorted()) ?? []
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rubbermac-fonts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stranger = faces[1].lastPathComponent
            let other = folder.appendingPathComponent("SomeOtherFont.otf")
            try Data("someone else's".utf8).write(to: folder.appendingPathComponent(stranger))
            try Data("another font".utf8).write(to: other)

            let first = try install(faces, into: folder)
            check(first == Outcome(copied: faces.count - 1, leftAlone: [stranger]),
                  "turning it on copies the \(faces.count - 1) missing faces and doesn't overwrite another file of the same name")
            check(!isInstalled(faces, in: folder), "so with that file in the way it isn't counted as on")
            try FileManager.default.removeItem(at: folder.appendingPathComponent(stranger))
            check(try install(faces, into: folder) == Outcome(copied: 1), "with it gone, turning it on copies that last face")
            check(isInstalled(faces, in: folder), "and then it counts as on")
            check(try install(faces, into: folder) == Outcome(), "turning it on again copies nothing")
            let copy = folder.appendingPathComponent(faces[0].lastPathComponent)
            check(((try? FileManager.default.attributesOfItem(atPath: copy.path)[.size]) as? Int)
                  == ((try? FileManager.default.attributesOfItem(atPath: faces[0].path)[.size]) as? Int),
                  "a copy is the whole file")

            let edited = faces[2].lastPathComponent
            try Data("edited since".utf8).write(to: folder.appendingPathComponent(edited))
            let off = try remove(faces, from: folder)
            check(off == Outcome(removed: faces.count - 1, leftAlone: [edited]),
                  "turning it off removes the \(faces.count - 1) faces that are still RubberMAC's and keeps a changed one")
            let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()) ?? []
            check(left == [edited, other.lastPathComponent].sorted(), "and every other file in the folder: \(left.joined(separator: ", "))")
            check(!isInstalled(faces, in: folder), "so it counts as off")
        } catch {
            check(false, "the scratch folder: \(error.localizedDescription)")
        }
        let realAfter = (try? FileManager.default.contentsOfDirectory(atPath: userFonts.path).sorted()) ?? []
        check(realAfter == realBefore, "~/Library/Fonts is untouched by the test")
        lines.append("on this Mac: \(isInstalled() ? "on" : "off"), \(elsewhere().count) file(s) of the family from elsewhere")
        return finish()
    }
}
