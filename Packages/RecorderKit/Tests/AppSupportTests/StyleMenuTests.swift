// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing
// Not @testable: the app uses only the public API.
import Editing

@Suite struct StyleMenuTests {
    private static let tutorials = NamedStyle(id: "0a1b2c3d", name: "Tutoriales", look: look(padding: 0.1), camera: .newProjects)
    private static let demos = NamedStyle(id: "a1b2c3d4", name: "Demos", look: look(padding: 0.05), camera: .newProjects)
    private static let styles = [demos, tutorials]

    private static func look(padding: Double) -> DefaultStyle {
        var look = DefaultStyle.toma
        look.style.padding = padding
        return look
    }

    /// A project of 1b with a look and a camera of its own, measured against the short side as a new project is.
    private static func document() -> EditDocument {
        let take = TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: [])
        var document = EditDocument.legacy(take: take, events: [])
        document.style.background = .gradient(start: RGBA(1, 0, 0, 1), end: RGBA(0, 0, 1, 1), angle: 45)
        document.style.padding = 0.12
        document.style.screenSampling = .mipmapped
        document.style.geometryTransition = .spring
        document.cursor.scale = 2
        document.cursor.style = .toma
        document.zoom.motionBlur = 0.3
        document.zoom.spring = SpringSpec(damping: 0.9, response: 0.4)
        document.camera.mirror = true
        document.camera.border = CameraBorder(width: 0.4, color: RGBA(0, 0, 0, 1))
        document.camera.shadow = 0.7
        document.camera.layout = CameraLayout(kind: .split, split: SplitLayout(side: .start, share: 0.4))
        document.camera.sizeReference = .shortSide
        return document
    }

    @Test func titleNamesTheMatchingStyle() {
        #expect(StyleMenu.title(.named(Self.tutorials.id), among: Self.styles) == .named("Tutoriales"))
        #expect(StyleMenu.title(.toma, among: Self.styles) == .toma)
        #expect(StyleMenu.title(.custom, among: Self.styles) == .custom)
        // A style that went from the library meanwhile is not named.
        #expect(StyleMenu.title(.named("ffffffff"), among: Self.styles) == .custom)
    }

    @Test func newProjectsTakeTheChosenStyleOrToma() {
        #expect(StyleMenu.newProjectsStyle(id: nil, among: Self.styles) == nil)
        #expect(StyleMenu.newProjectsStyle(id: Self.tutorials.id, among: Self.styles) == Self.tutorials)
        // Deleted from Finder, or damaged: Toma's style.
        #expect(StyleMenu.newProjectsStyle(id: "ffffffff", among: Self.styles) == nil)

        // The star: on the chosen style, else on Toma's.
        #expect(StyleMenu.isForNewProjects(Self.tutorials.id, newProjectsStyleID: Self.tutorials.id, among: Self.styles))
        #expect(!StyleMenu.isForNewProjects(Self.demos.id, newProjectsStyleID: Self.tutorials.id, among: Self.styles))
        #expect(!StyleMenu.isForNewProjects(NamedStyle.tomaStyleID, newProjectsStyleID: Self.tutorials.id, among: Self.styles))
        #expect(StyleMenu.isForNewProjects(NamedStyle.tomaStyleID, newProjectsStyleID: nil, among: Self.styles))
        #expect(StyleMenu.isForNewProjects(NamedStyle.tomaStyleID, newProjectsStyleID: "ffffffff", among: Self.styles))
        #expect(!StyleMenu.isForNewProjects("ffffffff", newProjectsStyleID: "ffffffff", among: Self.styles))
    }

    @Test func actionsFollowTheStyle() {
        let saved = StyleMenu.actions(for: Self.demos.id, newProjectsStyleID: Self.tutorials.id, among: Self.styles, canEdit: true)
        #expect(saved == StyleActions(canApply: true, canChangeFile: true, canUseForNewProjects: true))
        // The one new projects take already.
        let chosen = StyleMenu.actions(for: Self.tutorials.id, newProjectsStyleID: Self.tutorials.id, among: Self.styles, canEdit: true)
        #expect(chosen == StyleActions(canApply: true, canChangeFile: true, canUseForNewProjects: false))
        // Toma's style has no file: it is not renamed, duplicated, deleted nor shown in Finder.
        let toma = StyleMenu.actions(for: NamedStyle.tomaStyleID, newProjectsStyleID: Self.tutorials.id, among: Self.styles, canEdit: true)
        #expect(toma == StyleActions(canApply: true, canChangeFile: false, canUseForNewProjects: true))
        let tomaChosen = StyleMenu.actions(for: NamedStyle.tomaStyleID, newProjectsStyleID: nil, among: Self.styles, canEdit: true)
        #expect(tomaChosen == StyleActions(canApply: true, canChangeFile: false, canUseForNewProjects: false))
        // A read-only project is not changed; its look can still be saved and the styles managed.
        let readOnly = StyleMenu.actions(for: Self.demos.id, newProjectsStyleID: nil, among: Self.styles, canEdit: false)
        #expect(readOnly == StyleActions(canApply: false, canChangeFile: true, canUseForNewProjects: true))
        // A style the library no longer has.
        let gone = StyleMenu.actions(for: "ffffffff", newProjectsStyleID: nil, among: Self.styles, canEdit: true)
        #expect(!gone.canChangeFile)
    }

    @Test func updateTargetIsTheStyleTheProjectHad() {
        // The project has the style exactly: updating it changes nothing.
        let same = StyleMenu.updateTarget(.named(Self.demos.id), lastNamedID: Self.tutorials.id, among: Self.styles)
        #expect(same == StyleUpdateTarget(style: Self.demos, changesIt: false))
        // Changed since it last had one in this window: that one.
        let changed = StyleMenu.updateTarget(.custom, lastNamedID: Self.tutorials.id, among: Self.styles)
        #expect(changed == StyleUpdateTarget(style: Self.tutorials, changesIt: true))
        #expect(
            StyleMenu.updateTarget(.toma, lastNamedID: Self.tutorials.id, among: Self.styles)
                == StyleUpdateTarget(style: Self.tutorials, changesIt: true))
        // Never had one here (a project of 1b, or one made before the style of the new projects changed): no style is
        // offered to be written over, not even the one of the new projects.
        #expect(StyleMenu.updateTarget(.custom, lastNamedID: nil, among: Self.styles) == nil)
        #expect(StyleMenu.updateTarget(.toma, lastNamedID: nil, among: Self.styles) == nil)
        // The last one went from the library.
        #expect(StyleMenu.updateTarget(.custom, lastNamedID: "ffffffff", among: Self.styles) == nil)
        // A match that went from the library meanwhile falls back to the last one.
        #expect(
            StyleMenu.updateTarget(.named("eeeeeeee"), lastNamedID: Self.demos.id, among: Self.styles)
                == StyleUpdateTarget(style: Self.demos, changesIt: true))
    }

    @Test func importNoticesNeverHideAFailure() {
        let added = StyleImportResult.added(Self.tutorials)
        // One file: the sentence of design §12, without its name.
        #expect(StyleMenu.importNotices([("Tutoriales.tomastyle", added)]) == [StyleImportNotice(result: added)])
        #expect(
            StyleMenu.importNotices([("Roto.tomastyle", .damaged)]) == [StyleImportNotice(result: .damaged)])
        #expect(StyleMenu.importNotices([("Roto.tomastyle", .failed)]) == [StyleImportNotice(result: .failed)])
        // A damaged file and then a good one: the failure is said, first, with its file's name, and so is the style
        // added.
        #expect(
            StyleMenu.importNotices([("Roto.tomastyle", .damaged), ("Tutoriales.tomastyle", added)])
                == [StyleImportNotice(result: .damaged, file: "Roto.tomastyle"), StyleImportNotice(result: added)])
        // Every failure in the order chosen, then the styles that were there already, then those added.
        let notices = StyleMenu.importNotices([
            ("Tutoriales.tomastyle", added), ("Lleno.tomastyle", .failed), ("a1b2c3d4.tomastyle", .alreadyInLibrary(Self.demos)),
            ("Roto.tomastyle", .damaged),
        ])
        #expect(
            notices == [
                StyleImportNotice(result: .failed, file: "Lleno.tomastyle"), StyleImportNotice(result: .damaged, file: "Roto.tomastyle"),
                StyleImportNotice(result: .alreadyInLibrary(Self.demos)), StyleImportNotice(result: added),
            ])
        #expect(notices.map(\.isFailure) == [true, true, false, false])
        #expect(StyleMenu.importNotices([]).isEmpty)
    }

    @Test func styleOfADocumentIsWhatApplyCopies() {
        let document = Self.document()
        let style = StyleMenu.style(of: document, id: "0f0f0f0f", name: "De este proyecto")
        #expect(style.id == "0f0f0f0f" && style.name == "De este proyecto")
        #expect(style.look.style == document.style && style.look.cursor == document.cursor)
        #expect(style.look.zoomShow == document.zoom.show && style.look.zoomAuto == document.zoom.auto)
        #expect(style.look.zoomSpring == document.zoom.spring && style.look.zoomMotionBlur == document.zoom.motionBlur)
        #expect(
            style.camera
                == CameraLook(
                    mirror: true, border: CameraBorder(width: 0.4, color: RGBA(0, 0, 0, 1)), shadow: 0.7,
                    layout: CameraLayout(kind: .split, split: SplitLayout(side: .start, share: 0.4)), sizeReference: .shortSide))
        // The project has it exactly: the row names it, and applying it changes nothing.
        #expect(StyleCommands.matchingStyle(document, among: Self.styles + [style]) == .named("0f0f0f0f"))
        let take = TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: [])
        #expect(StyleCommands.applyStyle(document, style, take: take, events: []) == nil)
        // Another project takes all of it.
        var other = EditDocument.legacy(take: take, events: [])
        other.cursor.style = .toma
        let step = StyleCommands.applyStyle(other, style, take: take, events: [])
        let applied = step.flatMap { try? other.applying($0.changes) }
        #expect(applied.map { StyleCommands.matchingStyle($0, among: [style]) } == .named("0f0f0f0f"))
    }

    @Test func applyingWhatTheProjectHasIsNothing() {
        let document = Self.document()
        let own = StyleMenu.style(of: document, id: "0f0f0f0f", name: "De este proyecto")
        #expect(StyleMenu.has(document, own))
        #expect(!StyleMenu.has(document, Self.tutorials))
        #expect(!StyleMenu.has(document, NamedStyle.toma(name: "Estilo de Toma")))
        // A project in Toma's style has Toma's style, and not a saved style it does not match.
        var toma = document
        toma.style = DefaultStyle.toma.style
        toma.cursor = DefaultStyle.toma.cursor
        toma.cursor.style = document.cursor.style
        toma.zoom.show = DefaultStyle.toma.zoomShow
        toma.zoom.auto = DefaultStyle.toma.zoomAuto
        toma.zoom.spring = DefaultStyle.toma.zoomSpring
        toma.zoom.motionBlur = DefaultStyle.toma.zoomMotionBlur
        toma.camera = CameraLook.newProjects.applied(to: toma.camera)
        #expect(StyleMenu.has(toma, NamedStyle.toma(name: "Estilo de Toma")))
        #expect(!StyleMenu.has(toma, own))
        // A saved style just like Toma's: the project has both.
        let likeToma = NamedStyle(id: "1a2b3c4d", name: "Como Toma", look: .toma, camera: .newProjects)
        #expect(StyleMenu.has(toma, likeToma))
        #expect(StyleCommands.matchingStyle(toma, among: [likeToma]) == .named("1a2b3c4d"))
    }

    @Test func namesAreTrimmedAndNeverEmpty() {
        #expect(StyleMenu.validName("  Tutoriales \n") == "Tutoriales")
        #expect(StyleMenu.validName("Clientes / Demos: 2026") == "Clientes / Demos: 2026")
        #expect(StyleMenu.validName("") == nil)
        #expect(StyleMenu.validName(" \t\n ") == nil)
    }

    @Test func copyNamesCount() {
        let copy: (String) -> String = { "\($0) copia" }
        let numbered: (String, Int) -> String = { "\($0) copia \($1)" }
        #expect(StyleMenu.copyName(of: "Demos", existing: ["Demos"], copy: copy, numbered: numbered) == "Demos copia")
        #expect(StyleMenu.copyName(of: "Demos", existing: ["Demos", "demos COPIA"], copy: copy, numbered: numbered) == "Demos copia 2")
        #expect(
            StyleMenu.copyName(of: "Demos", existing: ["Demos", "Demos copia", "Demos copia 2"], copy: copy, numbered: numbered)
                == "Demos copia 3")
        // "Café" composed and decomposed is one name.
        #expect(StyleMenu.copyName(of: "Café", existing: ["Cafe\u{301} copia"], copy: copy, numbered: numbered) == "Café copia 2")
    }

    @Test func newIDsAreFreshHexIDs() {
        var draws: [UInt32] = [0x0A1B_2C3D, 0xA1B2_C3D4, 0x0000_00FF]
        let id = StyleMenu.newID(avoiding: ["0a1b2c3d", "a1b2c3d4"]) { draws.removeFirst() }
        #expect(id == "000000ff")
        #expect(draws.isEmpty)
        // Whatever the draws give, a free id of 8 lowercase hex digits.
        let stuck = StyleMenu.newID(avoiding: ["00000007", "00000000", "00000001"]) { 7 }
        #expect(stuck == "00000002")
        let any = StyleMenu.newID(avoiding: [])
        #expect(any.count == 8 && any.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func styleFilesAreKnownByTheirExtension() async throws {
        #expect(StyleMenu.isStyleFile(URL(fileURLWithPath: "/Users/x/Downloads/Tutoriales.tomastyle")))
        #expect(StyleMenu.isStyleFile(URL(fileURLWithPath: "/Users/x/Downloads/TUTORIALES.TomaStyle")))
        #expect(!StyleMenu.isStyleFile(URL(fileURLWithPath: "/Users/x/Movies/Toma/Demo.toma")))
        #expect(!StyleMenu.isStyleFile(URL(fileURLWithPath: "/Users/x/Downloads/tomastyle")))
        // The packages the library makes have that extension.
        try await withTemporaryDirectory { directory in
            let library = StyleLibrary(directory: directory) { _ in }
            try await library.save(Self.demos, imageFrom: nil)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
            #expect(names == ["a1b2c3d4." + StyleMenu.fileExtension])
            #expect(names.allSatisfy { StyleMenu.isStyleFile(directory.appending(path: $0)) })
            #expect(StyleMenu.isInLibrary(directory.appending(path: names[0]), directory: directory))
        }
    }

    @Test func aPackageOfTheLibraryIsNotImportedAgain() throws {
        let library = URL(fileURLWithPath: "/Users/x/Library/Application Support/Toma/Styles", isDirectory: true)
        #expect(StyleMenu.isInLibrary(library.appending(path: "0a1b2c3d.tomastyle"), directory: library))
        #expect(
            StyleMenu.isInLibrary(
                URL(fileURLWithPath: "/Users/x/Library/Application Support/Toma/Styles/./0a1b2c3d.tomastyle/"), directory: library))
        #expect(!StyleMenu.isInLibrary(URL(fileURLWithPath: "/Users/x/Downloads/0a1b2c3d.tomastyle"), directory: library))
        #expect(!StyleMenu.isInLibrary(library.appending(path: "Sub/0a1b2c3d.tomastyle"), directory: library))
        // Through a link to the library's folder, it is still the library's.
        try withTemporaryDirectory { directory in
            let real = directory.appending(path: "Styles", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
            let link = directory.appending(path: "Link", directoryHint: .isDirectory)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            #expect(StyleMenu.isInLibrary(link.appending(path: "0a1b2c3d.tomastyle"), directory: real))
        }
    }

    @Test func migratedStyleIsForNewProjectsOnlyIfNoneWasChosen() {
        #expect(StyleMenu.newProjectsStyleID(nil, migrated: Self.tutorials) == Self.tutorials.id)
        // Chosen while an earlier launch could not read the style of 1b: kept.
        #expect(StyleMenu.newProjectsStyleID(Self.demos.id, migrated: Self.tutorials) == Self.demos.id)
        #expect(StyleMenu.newProjectsStyleID(nil, migrated: nil) == nil)
        #expect(StyleMenu.newProjectsStyleID(Self.demos.id, migrated: nil) == Self.demos.id)
    }
}
