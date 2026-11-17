import CoreText
import Foundation

extension BundledFont {
    /// --selftest fonts: the app carries the 28 faces of Next and Mono and their licences, and turning them on and off works on a
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
        check(faces.count == 28, "the app carries \(faces.count) faces (28 expected)")
        for family in families {
            let own = Self.faces(of: family, faces)
            check(own.count == 14, "\(own.count) of them are \(family)'s (14 expected)")
            let folder = family.replacingOccurrences(of: " ", with: "")
            let licence = Bundle.main.resourceURL?.appendingPathComponent("Fonts/\(folder)/OFL.txt")
            check(licence.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("SIL OPEN FONT LICENSE Version 1.1") == true,
                  "with its licence, Fonts/\(folder)/OFL.txt")
            let fonts = own.flatMap { CTFontManagerCreateFontDescriptorsFromURL($0 as CFURL) as? [CTFontDescriptor] ?? [] }
                .map { CTFontCreateWithFontDescriptor($0, 12, nil) }
            check(fonts.count == own.count && fonts.allSatisfy { CTFontCopyFamilyName($0) as String == family },
                  "each file is one font of \(family)")
            check(fonts.allSatisfy { (CTFontCopyName($0, kCTFontLicenseNameKey) as String?)?.contains("SIL Open Font License") == true },
                  "each carries its licence notice")
            let styles = Set(fonts.compactMap { CTFontCopyName($0, kCTFontStyleNameKey) as String? })
            check(styles.isSuperset(of: ["Regular", "Italic", "Bold", "Bold Italic", "ExtraLight", "ExtraBold"]),
                  "the styles run from ExtraLight to ExtraBold, each with an italic: \(styles.sorted().joined(separator: ", "))")
            if family == monoFamily {
                let widths = fonts.map { font -> Set<Double> in
                    var glyphs = [CGGlyph](repeating: 0, count: 4), advances = [CGSize](repeating: .zero, count: 4)
                    CTFontGetGlyphsForCharacters(font, Array("iWm0".utf16), &glyphs, 4)
                    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, 4)
                    return Set(advances.map { ($0.width * 1000).rounded() })
                }
                check(widths.allSatisfy { $0.count == 1 }, "Mono is monospaced: i, W, m and 0 are as wide in every face")
            }
        }
        check(Set(faces.map(\.lastPathComponent)).count == faces.count, "no two faces share a file name, so they sit side by side in ~/Library/Fonts")
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

            // Turned on before the app carried Mono: Next is there and Mono is added to match, once.
            let upgrade = folder.appendingPathComponent("upgrade")
            try FileManager.default.createDirectory(at: upgrade, withIntermediateDirectories: true)
            try install(Self.faces(of: family, faces), into: upgrade)
            check(try completeEarlierInstall(faces, in: upgrade) == Outcome(copied: 14) && isInstalled(faces, in: upgrade),
                  "with Next on from before, the 14 Mono faces are added and it all counts as on")
            check(try completeEarlierInstall(faces, in: upgrade) == nil, "and that happens only once")
            let empty = folder.appendingPathComponent("empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            check(try completeEarlierInstall(faces, in: empty) == nil
                  && (try? FileManager.default.contentsOfDirectory(atPath: empty.path))?.isEmpty == true, "with the font off, nothing is added")
        } catch {
            check(false, "the scratch folder: \(error.localizedDescription)")
        }
        let realAfter = (try? FileManager.default.contentsOfDirectory(atPath: userFonts.path).sorted()) ?? []
        check(realAfter == realBefore, "~/Library/Fonts is untouched by the test")
        lines.append("on this Mac: \(isInstalled() ? "on" : "off"), \(elsewhere().count) file(s) of the families from elsewhere")
        return finish()
    }
}
