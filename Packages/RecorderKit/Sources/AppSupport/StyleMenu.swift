// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ProjectFormat

/// What the row Style of the editor's panel says (1c design §8). The app names Toma's style and "Custom".
public enum StyleRowTitle: Equatable, Sendable {
    /// The saved style the project has exactly, by its name.
    case named(String)
    case toma
    case custom
}

/// What can be done with one style of the row's menu or of "Manage Styles…" (1c design §8).
public struct StyleActions: Equatable, Sendable {
    /// "Apply": the project can be changed.
    public var canApply: Bool
    /// Rename, Duplicate, Delete and Show in Finder: a style of the library, not Toma's, which has no file.
    public var canChangeFile: Bool
    /// "Use for New Projects": new projects do not take it already.
    public var canUseForNewProjects: Bool

    public init(canApply: Bool, canChangeFile: Bool, canUseForNewProjects: Bool) {
        self.canApply = canApply
        self.canChangeFile = canChangeFile
        self.canUseForNewProjects = canUseForNewProjects
    }
}

/// The style "Update “X” with This Project" saves the project's look over.
public struct StyleUpdateTarget: Equatable, Sendable {
    public var style: NamedStyle
    /// Whether the project's look differs from the style's: if not, there is nothing to update.
    public var changesIt: Bool

    public init(style: NamedStyle, changesIt: Bool) {
        self.style = style
        self.changesIt = changesIt
    }
}

/// How importing one `.tomastyle` went (1c design §8 and §10).
public enum StyleImportResult: Equatable, Sendable {
    case added(NamedStyle)
    /// It is a package of the library already (opened after "Show in Finder"): nothing was copied.
    case alreadyInLibrary(NamedStyle)
    /// It cannot be read as a style (`StyleLibraryError.damaged`).
    case damaged
    /// The disk failed: nothing was added.
    case failed
}

/// One line of what the app says after an import.
public struct StyleImportNotice: Equatable, Sendable {
    public var result: StyleImportResult
    /// The name of the file that failed, when several were imported at once: which one. `nil` for a single file, which
    /// the sentence of design §12 says without its name, and for a style, which its own name tells.
    public var file: String?

    public init(result: StyleImportResult, file: String? = nil) {
        self.result = result
        self.file = file
    }

    /// Whether the line says that a file was not imported.
    public var isFailure: Bool {
        switch result {
        case .damaged, .failed: true
        case .added, .alreadyInLibrary: false
        }
    }
}

/// The rules of the named styles in the app (1c design §8): the row Style of the panel, its menu and the sheet "Manage
/// Styles…", as functions of the library's styles (`StyleLibrary.list()`), the project's match
/// (`StyleCommands.matchingStyle`) and the style of the new projects (`RecorderSettings.newProjectsStyleID`, `nil` for
/// Toma's style).
public enum StyleMenu {
    /// The extension of a style's package (`<id>.tomastyle`, plan decision 28): `STYLE_FILE_EXTENSION` of
    /// `Config/Identity.xcconfig`, and the one `StyleLibrary` names its packages with.
    public static let fileExtension = "tomastyle"

    /// What the row says for `match`: the name of the saved style, Toma's style or "Custom". A style that is no longer in
    /// `styles` is not named.
    public static func title(_ match: StyleMatch, among styles: [NamedStyle]) -> StyleRowTitle {
        switch match {
        case let .named(id): styles.first { $0.id == id }.map { .named($0.name) } ?? .custom
        case .toma: .toma
        case .custom: .custom
        }
    }

    /// The style new projects take: the one of `id` among `styles`; `nil`, Toma's style, without an id or if no style has
    /// it any more (deleted from Finder, or damaged).
    public static func newProjectsStyle(id: String?, among styles: [NamedStyle]) -> NamedStyle? {
        guard let id else { return nil }
        return styles.first { $0.id == id }
    }

    /// Whether the style of `id` (`NamedStyle.tomaStyleID` for Toma's) is the one new projects take: the one the menu
    /// stars.
    public static func isForNewProjects(_ id: String, newProjectsStyleID: String?, among styles: [NamedStyle]) -> Bool {
        (newProjectsStyle(id: newProjectsStyleID, among: styles)?.id ?? NamedStyle.tomaStyleID) == id
    }

    /// What can be done with the style of `id` (`NamedStyle.tomaStyleID` for Toma's) in a project that `canEdit` or not.
    public static func actions(for id: String, newProjectsStyleID: String?, among styles: [NamedStyle], canEdit: Bool) -> StyleActions {
        StyleActions(
            canApply: canEdit,
            canChangeFile: id != NamedStyle.tomaStyleID && styles.contains { $0.id == id },
            canUseForNewProjects: !isForNewProjects(id, newProjectsStyleID: newProjectsStyleID, among: styles))
    }

    /// Whether `document` has `style` exactly (`StyleCommands.matchingStyle`), so "Apply" has nothing to change that the
    /// user would see: Toma's style (`NamedStyle.tomaStyleID`) or a saved one, whichever other style would match too.
    public static func has(_ document: EditDocument, _ style: NamedStyle) -> Bool {
        StyleCommands.matchingStyle(document, among: [style]) == (style.id == NamedStyle.tomaStyleID ? .toma : .named(style.id))
    }

    /// The style "Update “X” with This Project" names: the one the project has exactly, else the last one it had in this
    /// window (`lastNamedID`); the first of those still in `styles`. `nil` if none is: a project that never had a saved
    /// style here (one of 1b, or one made before the style of the new projects changed) is never offered to write over
    /// one, and Toma's style is never updated.
    public static func updateTarget(_ match: StyleMatch, lastNamedID: String?, among styles: [NamedStyle]) -> StyleUpdateTarget? {
        var matched: String?
        if case let .named(id) = match { matched = id }
        for id in [matched, lastNamedID].compactMap({ $0 }) {
            if let style = styles.first(where: { $0.id == id }) { return StyleUpdateTarget(style: style, changesIt: id != matched) }
        }
        return nil
    }

    /// The look of `document` as a style of `id` named `name`, what "Save as New Style…" and "Update" save: its stage, its
    /// whole cursor, its zoom's settings, and its camera's look (mirror, border, shadow, the project's layout with its
    /// split, and its size's reference, which `StyleLibrary.save` makes the short side). What "Apply" copies back.
    public static func style(of document: EditDocument, id: String, name: String) -> NamedStyle {
        let look = DefaultStyle(
            style: document.style, cursor: document.cursor, zoomShow: document.zoom.show, zoomAuto: document.zoom.auto,
            zoomSpring: document.zoom.spring, zoomMotionBlur: document.zoom.motionBlur)
        let camera = document.camera
        return NamedStyle(
            id: id, name: name, look: look,
            camera: CameraLook(
                mirror: camera.mirror, border: camera.border, shadow: camera.shadow, layout: camera.layout,
                sizeReference: camera.sizeReference))
    }

    /// `raw` without the spaces and new lines at its ends, if something is left: a style's name is only shown, never a
    /// file's (its package is named by its id), so any other character may be in it.
    public static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The name of a copy of the style `name` among styles named `existing`: `copy(name)` («Demos copia») or, while that
    /// is taken, `numbered(name, n)` for n = 2, 3, … («Demos copia 2»). Two names that differ only in case or in Unicode
    /// normalization are the same name.
    public static func copyName(
        of name: String, existing: [String], copy: (String) -> String, numbered: (String, Int) -> String
    ) -> String {
        let taken = Set(existing.map(key))
        let first = copy(name)
        if !taken.contains(key(first)) { return first }
        var number = 2
        // `first` and `numbered(2)` … `numbered(existing.count + 1)` are `existing.count + 1` different names: one is free.
        while taken.contains(key(numbered(name, number))), number <= existing.count + 1 {
            number += 1
        }
        return numbered(name, number)
    }

    /// A new style's id: 8 lowercase hex digits from `random` that none of `ids` is (`StyleLibrary.save` writes over the
    /// style of its id); if the draws give only ids in use, the first free one counting from 0.
    public static func newID(avoiding ids: Set<String>, random: () -> UInt32 = { UInt32.random(in: .min ... .max) }) -> String {
        for _ in 0..<16 {
            let id = hex(random())
            if !ids.contains(id) { return id }
        }
        var number: UInt32 = 0
        while ids.contains(hex(number)) { number += 1 }
        return hex(number)
    }

    /// Whether `url` names a style's package by its extension, as Finder hands one to the app.
    public static func isStyleFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// Whether `url` is a package right inside the library's folder `directory`: opening it from Finder ("Show in
    /// Finder") is not importing it again. Links are resolved, so it reads the disk: call it off the main thread.
    public static func isInLibrary(_ url: URL, directory: URL) -> Bool {
        // The folder's links, not the package's: a package that is a link is not one (`StyleLibrary` never follows it).
        let folder = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        return folder.path == directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// What the app says after importing `results`, each file's name and how it went, in the order chosen: every failure
    /// first, then the styles that were in the library already, then those added, so a failure is never hidden behind a
    /// later success. A failure names its file when several were imported at once.
    public static func importNotices(_ results: [(file: String, result: StyleImportResult)]) -> [StyleImportNotice] {
        let several = results.count > 1
        let failures = results.compactMap { file, result -> StyleImportNotice? in
            let notice = StyleImportNotice(result: result, file: several ? file : nil)
            return notice.isFailure ? notice : nil
        }
        let already = results.compactMap { _, result -> StyleImportNotice? in
            if case .alreadyInLibrary = result { StyleImportNotice(result: result) } else { nil }
        }
        let added = results.compactMap { _, result -> StyleImportNotice? in
            if case .added = result { StyleImportNotice(result: result) } else { nil }
        }
        return failures + already + added
    }

    /// The style of the new projects once the style of 1b was migrated (`StyleLibrary.migrateLegacyDefault`): the one
    /// chosen, if one was (while a launch could not read the style of 1b), else the migrated one, if there is one.
    public static func newProjectsStyleID(_ current: String?, migrated: NamedStyle?) -> String? {
        current ?? migrated?.id
    }

    /// What two names that are the same name share: case folded; `String` compares by canonical equivalence.
    private static func key(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: nil)
    }

    private static func hex(_ value: UInt32) -> String {
        String(format: "%08x", value)
    }
}
