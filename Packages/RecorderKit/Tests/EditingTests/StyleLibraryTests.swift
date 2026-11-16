// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import RecorderKitTestSupport
import Synchronization
import Testing
import UniformTypeIdentifiers
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// What the tests of this file share.
private enum StyleFixture {
    /// A look unlike Toma's, so one that comes back as Toma's is told apart.
    static var look: DefaultStyle {
        var look = DefaultStyle.toma
        look.style.padding = 0.05
        look.style.background = .wallpaper("dune-1")
        look.cursor.scale = 2
        look.zoomAuto.depth = 2.5
        return look
    }

    /// A style of `look` with a camera unlike a new project's.
    static func style(id: String, name: String) -> NamedStyle {
        NamedStyle(
            id: id, name: name, look: look,
            camera: CameraLook(
                mirror: false, border: CameraBorder(width: 0.5, color: RGBA(1, 0.5, 0, 1)), shadow: 0.7,
                layout: CameraLayout(kind: .split, split: SplitLayout(side: .start, share: 0.4)), sizeReference: .shortSide))
    }

    /// The library `<dir>/<folder>`, with a trash that records an issue: no test but the one of `delete` trashes anything,
    /// and none ever reaches the real Trash.
    static func library(in dir: URL, folder: String = "Styles") -> StyleLibrary {
        StyleLibrary(directory: dir.appending(path: folder, directoryHint: .isDirectory)) { url in
            Issue.record("trashed \(url.path)")
        }
    }

    /// A `width` × `height` PNG filled with `red`.
    static func png(red: Double, width: Int = 32, height: Int = 32) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw TestSupportError.failed("no context") }
        context.setFillColor(CGColor(red: red, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestSupportError.failed("no image") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw TestSupportError.failed("no destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestSupportError.failed("no PNG") }
        return data as Data
    }

    /// A project folder `<name>.toma` holding `png` in its `assets/`, copied as a background is, and the path its document
    /// names it by, `assets/<sha>.png`.
    static func package(in dir: URL, name: String, png: Data) throws -> (package: ProjectPackage, file: String) {
        let package = ProjectPackage(url: dir.appending(path: "\(name).toma", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: true)
        let picked = dir.appending(path: "\(name).png")
        try png.write(to: picked)
        return (package, try AssetImport.copy(picked, into: package))
    }

    /// The name of the file `assets/<name>`.
    static func name(of file: String) -> String { String(file.dropFirst("assets/".count)) }

    /// The names in the folder at `url`; none if there is no folder.
    static func names(in url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
    }

    /// Every file under `url`, by its path from there, with its bytes.
    static func files(under url: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for case let path as String in FileManager.default.enumerator(atPath: url.path) ?? NSEnumerator() {
            let file = url.appending(path: path)
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue {
                files[path] = try Data(contentsOf: file)
            }
        }
        return files
    }

    /// 8 lowercase hex digits.
    static func isID(_ id: String) -> Bool {
        id.utf8.count == 8 && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Makes the item at `url` an hour old, as one a crash left long ago.
    static func age(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: url.path)
    }
}

/// Stands in for the macOS Trash: moves what it is given into a folder of the test's, and remembers it.
private final class TrashDouble: Sendable {
    let folder: URL
    private let trashed = Mutex<[URL]>([])

    init(folder: URL) {
        self.folder = folder
    }

    var calls: [URL] { trashed.withLock { $0 } }

    func trash(_ url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: folder.appending(path: url.lastPathComponent))
        trashed.withLock { $0.append(url) }
    }
}

@Test func saveListRoundTrip() async throws {
    #expect(StyleLibrary.defaultDirectory.standardizedFileURL.path.hasSuffix("/Library/Application Support/Toma/Styles"))
    try await withTemporaryDirectory { dir in
        let library = StyleFixture.library(in: dir)
        // Nothing saved yet, not even the folder: no styles.
        #expect(library.list().isEmpty)

        let tutorials = StyleFixture.style(id: "0a1b2c3d", name: "Tutoriales")
        var demos = StyleFixture.style(id: "ffff0001", name: "Demos")
        demos.look.style.cornerRadius = 0.03
        demos.camera = .newProjects
        try await library.save(tutorials, imageFrom: nil)
        try await library.save(demos, imageFrom: nil)
        // Both, as they were saved, by name.
        #expect(library.list() == [demos, tutorials])

        // `<id>.tomastyle/style.json`, in version 1, holding the style as `NamedStyle` encodes it (plan decision 29).
        let file = library.directory.appending(path: "0a1b2c3d.tomastyle/style.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(Set(json.keys) == ["camera", "id", "name", "style", "version"])
        #expect(json["version"] as? Int == 1)
        #expect(try ProjectJSON.decoder().decode(NamedStyle.self, from: Data(contentsOf: file)) == tutorials)
        #expect(StyleFixture.names(in: library.directory.appending(path: "0a1b2c3d.tomastyle")) == ["style.json"])

        // Saved again with its id: replaced, still two.
        var updated = tutorials
        updated.look.cursor.scale = 1
        try await library.save(updated, imageFrom: nil)
        #expect(library.list() == [demos, updated])

        // What is not a style of the library is not listed: another file, a folder without `style.json`, a damaged one,
        // one of a newer version, one not named by an id, and a link to a style. A package whose file says another id
        // is listed by its own name, the one every call finds it by.
        let manager = FileManager.default
        try Data().write(to: library.directory.appending(path: ".DS_Store"))
        try manager.createDirectory(at: library.directory.appending(path: "abcdef01.tomastyle"), withIntermediateDirectories: false)
        for (name, content) in [
            ("abcdef02", Data("{\"name\":".utf8)),
            ("abcdef03", try Data(contentsOf: file).replacing(Data("\"version\" : 1".utf8), with: Data("\"version\" : 2".utf8))),
            ("Tutoriales", try Data(contentsOf: file)),
            ("abcdef05", try Data(contentsOf: file)),
        ] {
            let package = library.directory.appending(path: "\(name).tomastyle")
            try manager.createDirectory(at: package, withIntermediateDirectories: false)
            try content.write(to: package.appending(path: "style.json"))
        }
        try manager.createSymbolicLink(
            at: library.directory.appending(path: "abcdef04.tomastyle"),
            withDestinationURL: library.directory.appending(path: "0a1b2c3d.tomastyle"))
        var renamedByHand = updated
        renamedByHand.id = "abcdef05"
        #expect(library.list() == [demos, updated, renamedByHand])

        // An id that is not 8 lowercase hex digits names no package: refused, and nothing is written.
        let before = StyleFixture.names(in: library.directory)
        for id in [NamedStyle.tomaStyleID, "../../evil", "0A1B2C3D", "1234567", "123456789", ""] {
            await #expect(throws: POSIXError(.EINVAL), "\(id)") {
                try await library.save(StyleFixture.style(id: id, name: "X"), imageFrom: nil)
            }
        }
        #expect(StyleFixture.names(in: library.directory) == before)
    }
}

@Test func savedStylesAlwaysMeasureAgainstTheShortSide() async throws {
    try await withTemporaryDirectory { dir in
        let library = StyleFixture.library(in: dir)
        // Saved from a project of 1b, which measures against the height.
        var old = StyleFixture.style(id: "00c0ffee", name: "Viejo")
        old.camera.sizeReference = .height
        try await library.save(old, imageFrom: nil)
        var expected = old
        expected.camera.sizeReference = .shortSide
        #expect(library.list() == [expected])

        // Toma's style: Toma's look and a new project's camera, which measures against the short side.
        #expect(NamedStyle.toma(name: "Estilo de Toma") == NamedStyle(
            id: NamedStyle.tomaStyleID, name: "Estilo de Toma", look: .toma, camera: .newProjects))
        #expect(NamedStyle.toma(name: "Toma").camera.sizeReference == .shortSide)
        #expect(NamedStyle.tomaStyleID == "toma")
    }
}

@Test func imageTravelsWithTheStyle() async throws {
    try await withTemporaryDirectory { dir in
        let library = StyleFixture.library(in: dir)
        let png = try StyleFixture.png(red: 0.1)
        let source = try StyleFixture.package(in: dir, name: "Source", png: png)
        let name = StyleFixture.name(of: source.file)
        var style = StyleFixture.style(id: "1234abcd", name: "Con imagen")
        style.look.style.background = .image(file: source.file)

        // In the style's own `assets/`, named as the project names it, where `imageDirectory` says.
        try await library.save(style, imageFrom: source.package)
        let images = library.imageDirectory(of: style)
        #expect(images.standardizedFileURL.path == library.directory.appending(path: "1234abcd.tomastyle/assets").standardizedFileURL.path)
        #expect(try Data(contentsOf: images.appending(path: name)) == png)
        #expect(library.list() == [style])

        // Saved again without the project: the image is there already, and stays.
        style.name = "Otra vez"
        try await library.save(style, imageFrom: nil)
        #expect(library.list() == [style])
        #expect(try Data(contentsOf: images.appending(path: name)) == png)

        // Another image takes the place of the first, which goes.
        let otherPNG = try StyleFixture.png(red: 0.9)
        let other = try StyleFixture.package(in: dir, name: "Other", png: otherPNG)
        style.look.style.background = .image(file: other.file)
        try await library.save(style, imageFrom: other.package)
        #expect(StyleFixture.names(in: images) == [StyleFixture.name(of: other.file)])
        #expect(try Data(contentsOf: images.appending(path: StyleFixture.name(of: other.file))) == otherPNG)

        // Another background: no image is left.
        style.look.style.background = .wallpaper("aurora-1")
        try await library.save(style, imageFrom: nil)
        #expect(!StyleFixture.exists(images))
        #expect(library.list() == [style])

        // An image it cannot take is Toma's background: without the project, named anywhere but `assets/`, or one that
        // does not decode there. The rest is saved.
        try Data("not a picture".utf8).write(to: other.package.url.appending(path: other.file))
        for (index, (file, package)) in [
            (source.file, nil), ("../\(name)", source.package), (other.file, other.package),
        ].enumerated() {
            var lost = StyleFixture.style(id: "5678abc\(index)", name: "Sin imagen \(index)")
            lost.look.style.background = .image(file: file)
            try await library.save(lost, imageFrom: package)
            lost.look.style.background = DefaultStyle.toma.style.background
            #expect(library.list().first { $0.id == lost.id } == lost)
            #expect(!StyleFixture.exists(library.imageDirectory(of: lost)))
        }
    }
}

@Test func renameAndDuplicateKeepEverythingElse() async throws {
    try await withTemporaryDirectory { dir in
        let library = StyleFixture.library(in: dir)
        let png = try StyleFixture.png(red: 0.2)
        let source = try StyleFixture.package(in: dir, name: "Source", png: png)
        var style = StyleFixture.style(id: "beefcafe", name: "Tutoriales")
        style.look.style.background = .image(file: source.file)
        try await library.save(style, imageFrom: source.package)

        try await library.rename(id: style.id, to: "Clases")
        var renamed = style
        renamed.name = "Clases"
        #expect(library.list() == [renamed])
        #expect(try Data(contentsOf: library.imageDirectory(of: style).appending(path: StyleFixture.name(of: source.file))) == png)

        // A copy under another id, with its own image.
        let copy = try await library.duplicate(id: style.id, name: "Clases 2")
        #expect(StyleFixture.isID(copy.id))
        #expect(copy.id != style.id)
        #expect(copy == NamedStyle(id: copy.id, name: "Clases 2", look: style.look, camera: style.camera))
        #expect(library.list() == [renamed, copy])
        #expect(try Data(contentsOf: library.imageDirectory(of: copy).appending(path: StyleFixture.name(of: source.file))) == png)

        // No such style: not found. A damaged one cannot be renamed or copied.
        for id in ["99999999", NamedStyle.tomaStyleID, "../Styles"] {
            await #expect(throws: StyleLibraryError.notFound, "\(id)") { try await library.rename(id: id, to: "X") }
            await #expect(throws: StyleLibraryError.notFound, "\(id)") { _ = try await library.duplicate(id: id, name: "X") }
        }
        try Data("{".utf8).write(to: library.directory.appending(path: "\(copy.id).tomastyle/style.json"))
        await #expect(throws: StyleLibraryError.damaged) { try await library.rename(id: copy.id, to: "X") }
        await #expect(throws: StyleLibraryError.damaged) { _ = try await library.duplicate(id: copy.id, name: "X") }
        #expect(library.list() == [renamed])
    }
}

@Test func importCopiesWithANewIDIfTaken() async throws {
    try await withTemporaryDirectory { dir in
        let library = StyleFixture.library(in: dir)
        let png = try StyleFixture.png(red: 0.3)
        let source = try StyleFixture.package(in: dir, name: "Source", png: png)
        let name = StyleFixture.name(of: source.file)
        var style = StyleFixture.style(id: "abcdef12", name: "Compartido")
        style.look.style.background = .image(file: source.file)
        try await library.save(style, imageFrom: source.package)

        // Sent to another Mac: the package as it is, under any name.
        let sent = dir.appending(path: "Sent/Compartido.tomastyle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: library.directory.appending(path: "abcdef12.tomastyle"), to: sent)
        let sentFiles = try StyleFixture.files(under: sent)

        // Where its id is free, it keeps it.
        let otherMac = StyleFixture.library(in: dir, folder: "Other Mac")
        #expect(try await otherMac.importPackage(sent) == style)
        #expect(otherMac.list() == [style])
        #expect(try Data(contentsOf: otherMac.imageDirectory(of: style).appending(path: name)) == png)

        // Where it is taken, another id and the same content, with its own image. The package opened stays as it was.
        for _ in 0..<2 {
            let copy = try await library.importPackage(sent)
            #expect(StyleFixture.isID(copy.id))
            var expected = style
            expected.id = copy.id
            #expect(copy == expected)
            #expect(try Data(contentsOf: library.imageDirectory(of: copy).appending(path: name)) == png)
        }
        let listed = library.list()
        #expect(listed.count == 3)
        #expect(Set(listed.map(\.id)).count == 3)
        #expect(try StyleFixture.files(under: sent) == sentFiles)

        // A package whose id is no id takes a new one.
        let file = sent.appending(path: "style.json")
        try Data(contentsOf: file).replacing(Data("\"abcdef12\"".utf8), with: Data("\"../toma\"".utf8)).write(to: file)
        let renumbered = try await otherMac.importPackage(sent)
        #expect(StyleFixture.isID(renumbered.id))
        #expect(renumbered.id != style.id)
        #expect(otherMac.list().count == 2)
    }
}

@Test func damagedOrLinkedStyleIsRefused() async throws {
    try await withTemporaryDirectory { dir in
        let manager = FileManager.default
        let png = try StyleFixture.png(red: 0.4)
        let source = try StyleFixture.package(in: dir, name: "Source", png: png)
        let name = StyleFixture.name(of: source.file)
        let first = StyleFixture.library(in: dir, folder: "First")
        var style = StyleFixture.style(id: "0badf00d", name: "Dañado")
        style.look.style.background = .image(file: source.file)
        try await first.save(style, imageFrom: source.package)
        let original = first.directory.appending(path: "0badf00d.tomastyle", directoryHint: .isDirectory)
        let library = StyleFixture.library(in: dir)
        try await library.save(StyleFixture.style(id: "00000001", name: "Ya estaba"), imageFrom: nil)
        let before = try StyleFixture.files(under: library.directory)
        // A whole PNG, but past the largest side a package's image is decoded at.
        let oversized = try StyleFixture.png(red: 0.4, width: PackageFileKind.asset.maxPixelSide + 1, height: 1)

        let damages: [(String, (URL) throws -> Void)] = [
            ("style.json is a link", { package in
                try manager.removeItem(at: package.appending(path: "style.json"))
                try manager.createSymbolicLink(
                    at: package.appending(path: "style.json"), withDestinationURL: original.appending(path: "style.json"))
            }),
            ("style.json is a FIFO", { package in
                try manager.removeItem(at: package.appending(path: "style.json"))
                #expect(mkfifo(package.appending(path: "style.json").path, 0o644) == 0)
            }),
            ("style.json is random bytes", { package in
                try Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }).write(to: package.appending(path: "style.json"))
            }),
            ("style.json is missing", { package in try manager.removeItem(at: package.appending(path: "style.json")) }),
            ("style.json is of a newer version", { package in
                let file = package.appending(path: "style.json")
                try Data(contentsOf: file).replacing(Data("\"version\" : 1".utf8), with: Data("\"version\" : 2".utf8)).write(to: file)
            }),
            ("the image is cut short", { package in
                try png.prefix(png.count / 2).write(to: package.appending(path: "assets/\(name)"))
            }),
            ("the image is wider than 16 384 px", { package in
                try oversized.write(to: package.appending(path: "assets/\(name)"))
            }),
            ("the image is missing", { package in try manager.removeItem(at: package.appending(path: "assets/\(name)")) }),
            ("assets is a link", { package in
                try manager.removeItem(at: package.appending(path: "assets"))
                try manager.createSymbolicLink(at: package.appending(path: "assets"), withDestinationURL: original.appending(path: "assets"))
            }),
            ("the image is named outside assets", { package in
                let file = package.appending(path: "style.json")
                try Data(contentsOf: file).replacing(Data("\"assets/".utf8), with: Data("\"../First/0badf00d.tomastyle/assets/".utf8))
                    .write(to: file)
            }),
            ("the package is a file", { package in
                try manager.removeItem(at: package)
                #expect(manager.createFile(atPath: package.path, contents: Data("not a style".utf8)))
            }),
        ]
        for (index, (what, damage)) in damages.enumerated() {
            let sent = dir.appending(path: "Sent \(index)/Estilo.tomastyle", directoryHint: .isDirectory)
            try manager.createDirectory(at: sent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: original, to: sent)
            try damage(sent)
            await #expect(throws: StyleLibraryError.damaged, "\(what)") { _ = try await library.importPackage(sent) }
            // Nothing copied, not even in part.
            #expect(try StyleFixture.files(under: library.directory) == before, "\(what)")
            #expect(StyleFixture.names(in: library.directory) == ["00000001.tomastyle"], "\(what)")
        }
        // Undamaged, the same package is taken.
        let sent = dir.appending(path: "Sent/Estilo.tomastyle", directoryHint: .isDirectory)
        try manager.createDirectory(at: sent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: original, to: sent)
        #expect(try await library.importPackage(sent) == style)
    }
}

@Test func deleteGoesToTheMacOSTrash() async throws {
    try await withTemporaryDirectory { dir in
        let bin = TrashDouble(folder: dir.appending(path: "Trash", directoryHint: .isDirectory))
        let library = StyleLibrary(directory: dir.appending(path: "Styles", directoryHint: .isDirectory)) { try bin.trash($0) }
        let png = try StyleFixture.png(red: 0.5)
        let source = try StyleFixture.package(in: dir, name: "Source", png: png)
        let kept = StyleFixture.style(id: "11111111", name: "Queda")
        var deleted = StyleFixture.style(id: "22222222", name: "Se va")
        deleted.look.style.background = .image(file: source.file)
        try await library.save(kept, imageFrom: nil)
        try await library.save(deleted, imageFrom: source.package)

        try await library.delete(id: deleted.id)
        #expect(library.list() == [kept])
        // The whole package, given to the trash as it was: it can be put back from Finder.
        #expect(bin.calls.map(\.path) == [library.directory.appending(path: "22222222.tomastyle").path])
        let trashed = bin.folder.appending(path: "22222222.tomastyle")
        #expect(try ProjectJSON.decoder().decode(NamedStyle.self, from: Data(contentsOf: trashed.appending(path: "style.json"))) == deleted)
        #expect(try Data(contentsOf: trashed.appending(path: "assets/\(StyleFixture.name(of: source.file))")) == png)

        // Gone already, never saved, or no id: not found, and nothing goes to the trash.
        for id in ["22222222", "33333333", NamedStyle.tomaStyleID, "../Styles", ""] {
            await #expect(throws: StyleLibraryError.notFound, "\(id)") { try await library.delete(id: id) }
        }
        #expect(bin.calls.count == 1)

        // A trash that fails: the style stays.
        let failing = StyleLibrary(directory: library.directory) { _ in throw CocoaError(.fileWriteNoPermission) }
        await #expect(throws: CocoaError.self) { try await failing.delete(id: kept.id) }
        #expect(library.list() == [kept])
    }
}

@Test func legacyDefaultBecomesTheNamedStyleOnce() async throws {
    try await withTemporaryDirectory { dir in
        let png = try StyleFixture.png(red: 0.6)
        let source = try StyleFixture.package(in: dir, name: "Source", png: png)
        var look = StyleFixture.look
        look.style.background = .image(file: source.file)
        let legacy = DefaultStyleStore(directory: dir.appending(path: "Style", directoryHint: .isDirectory))
        try await legacy.save(look, from: source.package)
        let legacyFiles = try StyleFixture.files(under: legacy.directory)

        // The style of 1b, with a new project's camera, under the name given; its image with it.
        let library = StyleFixture.library(in: dir)
        let migrated = try #require(try await library.migrateLegacyDefault(from: legacy.directory, named: "Mi estilo"))
        #expect(StyleFixture.isID(migrated.id))
        #expect(migrated == NamedStyle(id: migrated.id, name: "Mi estilo", look: look, camera: .newProjects))
        #expect(migrated.camera.sizeReference == .shortSide)
        #expect(library.list() == [migrated])
        #expect(try Data(contentsOf: library.imageDirectory(of: migrated).appending(path: StyleFixture.name(of: source.file))) == png)
        #expect(StyleFixture.exists(library.directory.appending(path: ".migrated-1b")))

        // Once.
        #expect(try await library.migrateLegacyDefault(from: legacy.directory, named: "Mi estilo") == nil)
        #expect(library.list() == [migrated])
        // The old style stays where it was, as it was.
        #expect(try StyleFixture.files(under: legacy.directory) == legacyFiles)
        #expect(legacy.load() == look)

        // A crash after the style was written but before the mark was: the next launch finds the style it wrote, and
        // never makes a second one.
        try FileManager.default.removeItem(at: library.directory.appending(path: ".migrated-1b"))
        #expect(try await library.migrateLegacyDefault(from: legacy.directory, named: "Mi estilo") == migrated)
        #expect(library.list() == [migrated])
        #expect(try await library.migrateLegacyDefault(from: legacy.directory, named: "Mi estilo") == nil)

        // Without a style of 1b: nothing, and never again, even if one shows up later.
        let fresh = StyleFixture.library(in: dir, folder: "Fresh")
        #expect(try await fresh.migrateLegacyDefault(from: dir.appending(path: "Nowhere"), named: "Mi estilo") == nil)
        #expect(try await fresh.migrateLegacyDefault(from: legacy.directory, named: "Mi estilo") == nil)
        #expect(fresh.list().isEmpty)

        // Its image lost: Toma's background, as 1b gave its new projects.
        try FileManager.default.removeItem(at: legacy.directory.appending(path: StyleFixture.name(of: source.file)))
        let lost = StyleFixture.library(in: dir, folder: "Lost")
        let withoutImage = try #require(try await lost.migrateLegacyDefault(from: legacy.directory, named: "Mi estilo"))
        var expected = look
        expected.style.background = DefaultStyle.toma.style.background
        #expect(withoutImage.look == expected)
        #expect(lost.list() == [withoutImage])
    }
}

@Test func concurrentWritesAllLand() async throws {
    try await withTemporaryDirectory { dir in
        // Two libraries of one folder, as two windows of the app may hold.
        let first = StyleFixture.library(in: dir)
        let second = StyleFixture.library(in: dir)
        let png = try StyleFixture.png(red: 0.7)
        let source = try StyleFixture.package(in: dir, name: "Source", png: png)
        let shared = {
            var shared = StyleFixture.style(id: "5a5a5a5a", name: "Compartido")
            shared.look.style.background = .image(file: source.file)
            return shared
        }()
        try await first.save(shared, imageFrom: source.package)
        let package = source.package

        let copies = try await withThrowingTaskGroup(of: NamedStyle?.self) { group in
            for index in 0..<8 {
                let library = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    try await library.save(StyleFixture.style(id: String(format: "%08x", index), name: "Estilo \(index)"), imageFrom: nil)
                    return nil
                }
                group.addTask {
                    var style = shared
                    style.name = "Compartido \(index)"
                    try await library.save(style, imageFrom: package)
                    return nil
                }
                group.addTask { try await library.duplicate(id: shared.id, name: "Copia \(index)") }
            }
            return try await group.reduce(into: [NamedStyle]()) { if let copy = $1 { $0.append(copy) } }
        }

        let listed = first.list()
        #expect(listed.count == 1 + 8 + 8)
        #expect(Set(copies.map(\.id)).count == 8)
        #expect(Set(listed.map(\.id)) == Set((0..<8).map { String(format: "%08x", $0) } + copies.map(\.id) + [shared.id]))
        let last = try #require(listed.first { $0.id == shared.id })
        #expect(last.name.hasPrefix("Compartido "))
        // Nothing half written is left about.
        for name in StyleFixture.names(in: first.directory) {
            #expect(name.hasSuffix(".tomastyle") && !name.hasPrefix("."), "\(name)")
        }
        #expect(StyleFixture.names(in: first.directory.appending(path: "\(shared.id).tomastyle")) == ["assets", "style.json"])
    }
}

@Test func aLegacyStyleThatCannotBeReadNowIsMigratedLater() async throws {
    try await withTemporaryDirectory { dir in
        let legacy = DefaultStyleStore(directory: dir.appending(path: "Style", directoryHint: .isDirectory))
        try await legacy.save(StyleFixture.look, from: nil)
        let file = legacy.directory.appending(path: "default-style.json")
        let library = StyleFixture.library(in: dir)

        // Not readable just now (a home folder copied with the wrong owner): its error, and no mark.
        #expect(chmod(file.path, 0) == 0)
        await #expect(throws: POSIXError(.EACCES)) {
            _ = try await library.migrateLegacyDefault(from: legacy.directory, named: "Mi estilo")
        }
        #expect(!StyleFixture.exists(library.directory.appending(path: ".migrated-1b")))
        #expect(library.list().isEmpty)

        // Readable again: the next launch migrates it.
        #expect(chmod(file.path, 0o644) == 0)
        let migrated = try #require(try await library.migrateLegacyDefault(from: legacy.directory, named: "Mi estilo"))
        #expect(migrated == NamedStyle(id: migrated.id, name: "Mi estilo", look: StyleFixture.look, camera: .newProjects))
        #expect(library.list() == [migrated])

        // One that reads but does not decode, or that can never be read (a FIFO), never will: nothing, marked once.
        let damages: [(String, (URL) throws -> Void)] = [
            ("does not decode", { try Data("{\"style\":".utf8).write(to: $0) }),
            ("is a FIFO", { url in
                try FileManager.default.removeItem(at: url)
                #expect(mkfifo(url.path, 0o644) == 0)
            }),
        ]
        for (index, (what, damage)) in damages.enumerated() {
            try damage(file)
            let other = StyleFixture.library(in: dir, folder: "Other \(index)")
            #expect(try await other.migrateLegacyDefault(from: legacy.directory, named: "Mi estilo") == nil, "\(what)")
            #expect(StyleFixture.exists(other.directory.appending(path: ".migrated-1b")), "\(what)")
            #expect(other.list().isEmpty, "\(what)")
        }
    }
}

@Test func anotherProcessesWorkIsLeftAlone() async throws {
    try await withTemporaryDirectory { dir in
        let manager = FileManager.default
        let library = StyleFixture.library(in: dir)
        let png = try StyleFixture.png(red: 0.8)
        let source = try StyleFixture.package(in: dir, name: "Source", png: png)
        let name = StyleFixture.name(of: source.file)
        var style = StyleFixture.style(id: "abababab", name: "Compartido")
        style.look.style.background = .image(file: source.file)
        try await library.save(style, imageFrom: source.package)
        let package = library.directory.appending(path: "abababab.tomastyle", directoryHint: .isDirectory)
        let assets = library.imageDirectory(of: style)

        // What another process of Toma is writing right now, and the same left by a crash an hour ago: a package being
        // built, the mark, a style.json and an image, each in a hidden folder or temporary file of a name of its own.
        func work() -> [URL] {
            [
                library.directory.appending(path: ".12345678-\(UUID().uuidString).staging", directoryHint: .isDirectory),
                library.directory.appending(path: "..migrated-1b.\(UUID().uuidString).tmp"),
                package.appending(path: ".style.json.\(UUID().uuidString).tmp"),
                assets.appending(path: ".\(name).\(UUID().uuidString).tmp"),
            ]
        }
        let underWay = work()
        let leftOver = work()
        for (urls, old) in [(underWay, false), (leftOver, true)] {
            try manager.createDirectory(at: urls[0], withIntermediateDirectories: false)
            try Data("{".utf8).write(to: urls[0].appending(path: "style.json"))
            for url in urls.dropFirst() { try Data("partial".utf8).write(to: url) }
            if old { try urls.forEach(StyleFixture.age) }
        }
        #expect(library.list() == [style])

        // A save over the package and a new one land; what a crash left goes, and what is under way stays as it was.
        style.name = "Compartido 2"
        try await library.save(style, imageFrom: nil)
        let new = StyleFixture.style(id: "cdcdcdcd", name: "Nuevo")
        try await library.save(new, imageFrom: nil)
        #expect(library.list() == [style, new])
        for url in leftOver { #expect(!StyleFixture.exists(url), "\(url.lastPathComponent)") }
        for url in underWay.dropFirst() { #expect(try Data(contentsOf: url) == Data("partial".utf8), "\(url.lastPathComponent)") }
        #expect(try Data(contentsOf: underWay[0].appending(path: "style.json")) == Data("{".utf8))
        #expect(try Data(contentsOf: assets.appending(path: name)) == png)
    }
}

@Test func crashMidSaveLeavesTheOldStyle() async throws {
    try await withTemporaryDirectory { dir in
        let library = StyleFixture.library(in: dir)
        let png = try StyleFixture.png(red: 0.15)
        let source = try StyleFixture.package(in: dir, name: "Source", png: png)
        let name = StyleFixture.name(of: source.file)
        var style = StyleFixture.style(id: "0c0c0c0c", name: "Antes")
        style.look.style.background = .image(file: source.file)
        try await library.save(style, imageFrom: source.package)
        let package = library.directory.appending(path: "0c0c0c0c.tomastyle", directoryHint: .isDirectory)
        let assets = library.imageDirectory(of: style)

        // A save of another image that a crash cut short after its image was written: the new image whole in `assets/`,
        // its style.json still in a temporary file, half written.
        let otherPNG = try StyleFixture.png(red: 0.85)
        let other = try StyleFixture.package(in: dir, name: "Other", png: otherPNG)
        try otherPNG.write(to: assets.appending(path: StyleFixture.name(of: other.file)))
        let temporary = package.appending(path: ".style.json.\(UUID().uuidString).tmp")
        try Data("{\n  \"camera\" : {\n    \"border\" : ".utf8).write(to: temporary)
        try StyleFixture.age(temporary)

        // The old style, as it was, with its image.
        #expect(library.list() == [style])
        #expect(try Data(contentsOf: assets.appending(path: name)) == png)

        // The next save clears both away.
        style.name = "Después"
        try await library.save(style, imageFrom: nil)
        #expect(library.list() == [style])
        #expect(StyleFixture.names(in: package) == ["assets", "style.json"])
        #expect(StyleFixture.names(in: assets) == [name])
    }
}

@Test func aVolumeWithoutExclusiveRenameStillTakesStyles() async throws {
    try await withTemporaryDirectory { dir in
        let disk = try DiskImage.attach(sizeMegabytes: 20, fileSystem: .exFAT, in: dir)
        defer { try? disk.detach(force: true) }
        // exFAT has no `RENAME_EXCL`.
        let probe = disk.mountPoint.appending(path: "Probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let moved = renamex_np(probe.path, disk.mountPoint.appending(path: "Probed").path, UInt32(RENAME_EXCL))
        let code = errno
        #expect(moved == -1 && (code == ENOTSUP || code == EINVAL))

        let library = StyleFixture.library(in: disk.mountPoint)
        let png = try StyleFixture.png(red: 0.35)
        let source = try StyleFixture.package(in: dir, name: "Source", png: png)
        let name = StyleFixture.name(of: source.file)
        var style = StyleFixture.style(id: "e0e0e0e0", name: "En exFAT")
        style.look.style.background = .image(file: source.file)
        // New, then over itself.
        try await library.save(style, imageFrom: source.package)
        #expect(library.list() == [style])
        style.name = "En exFAT 2"
        try await library.save(style, imageFrom: nil)
        #expect(library.list() == [style])
        // A copy, and an import whose id is taken: the move finds it there, and the style takes another id.
        let copy = try await library.duplicate(id: style.id, name: "Copia")
        let sent = dir.appending(path: "Sent/Estilo.tomastyle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: library.directory.appending(path: "e0e0e0e0.tomastyle"), to: sent)
        let imported = try await library.importPackage(sent)
        #expect(imported.id != style.id)
        var expected = style
        expected.id = imported.id
        #expect(imported == expected)
        #expect(Set(library.list().map(\.id)) == [style.id, copy.id, imported.id])
        for added in [style, copy, imported] {
            #expect(try Data(contentsOf: library.imageDirectory(of: added).appending(path: name)) == png, "\(added.name)")
        }
    }
}
