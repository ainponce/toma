// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Foundation
import Observation
import ProjectFormat
import UniformTypeIdentifiers
import os

/// How importing a `.tomastyle` went.
enum StyleImportOutcome: Equatable {
    case added(NamedStyle)
    /// It is a package of the library already (opened from "Show in Finder"): nothing is copied.
    case alreadyInLibrary
    /// `StyleLibraryError.damaged`: it cannot be read as a style.
    case damaged
    /// The disk failed: nothing was added.
    case failed
}

/// The user's named styles as the app shows them (1c design §8), one for the whole app: the library's styles, read off the
/// main thread, and the style of the new projects (`RecorderSettings.newProjectsStyleID`). Every change goes through it,
/// and it reads the library again after each, so the row Style of every editor and the sheet "Manage Styles…" show the
/// same styles. At launch it moves the default style of 1b into the library once, as «My Style», for the new projects.
@MainActor @Observable
final class StyleCatalog {
    static let shared = StyleCatalog()

    /// The library's styles, by name.
    private(set) var styles: [NamedStyle] = []
    /// The style chosen for new projects, as the settings keep it; `nil`: Toma's style.
    private(set) var newProjectsStyleID: String?

    @ObservationIgnored let library = StyleLibrary(directory: StyleLibrary.defaultDirectory)
    @ObservationIgnored private let settings = SettingsStore()
    @ObservationIgnored private var launch: Task<Void, Never>?
    /// Each reading of the library counts: one that ends after a later one began is not shown.
    @ObservationIgnored private var readings = 0

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Styles")

    /// The type of a style's package (`STYLE_TYPE_IDENTIFIER`, plan decision 28), as the app declares it.
    static let fileType = UTType(filenameExtension: StyleMenu.fileExtension, conformingTo: .package) ?? .package

    /// Toma's style, named in the user's language.
    static var toma: NamedStyle { NamedStyle.toma(name: String(localized: "Toma's Style", comment: "The style a project has when nothing was changed")) }

    private init() {
        newProjectsStyleID = settings.settings.newProjectsStyleID
    }

    // MARK: - Launch

    /// Starts the launch's work, once: the style of 1b migrated, then the library read.
    func start() {
        _ = launched
    }

    private var launched: Task<Void, Never> {
        if let launch { return launch }
        let task = Task {
            await migrate()
            await reload()
        }
        launch = task
        return task
    }

    /// The default style of 1b becomes «My Style», for the new projects unless a style was chosen for them meanwhile (a
    /// launch that could not read it: `migrateLegacyDefault` looks again at the next one).
    private func migrate() async {
        let library = library, name = String(localized: "My Style", comment: "The style made from the default style of an earlier version")
        do {
            guard let migrated = try await library.migrateLegacyDefault(from: DefaultStyleStore.defaultDirectory, named: name) else { return }
            setNewProjectsStyle(StyleMenu.newProjectsStyleID(newProjectsStyleID, migrated: migrated))
            Self.logger.notice("The default style of 1b is now the style \(migrated.id, privacy: .public)")
        } catch {
            Self.logger.error("Cannot read the default style of 1b, looked for again at the next launch: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Reading

    /// Reads the library again, off the main thread.
    func reload() async {
        readings += 1
        let reading = readings, library = library
        let styles = await Task.detached(priority: .userInitiated) { library.list() }.value
        guard reading == readings else { return }
        self.styles = styles
    }

    /// The style new projects take, and the folder of its image (`EditContext.defaultStyle`, `styleDirectory` and
    /// `cameraLook`): once the launch's migration is done, from the library as it is now; Toma's style if the one chosen
    /// is not there any more.
    func newProjectsStyle() async -> (style: NamedStyle, imageDirectory: URL?) {
        await launched.value
        await reload()
        guard let style = StyleMenu.newProjectsStyle(id: newProjectsStyleID, among: styles) else { return (Self.toma, nil) }
        return (style, library.imageDirectory(of: style))
    }

    /// The folder of `style`'s image, for "Apply"; none for Toma's style.
    func imageDirectory(of style: NamedStyle) -> URL? {
        style.id == NamedStyle.tomaStyleID ? nil : library.imageDirectory(of: style)
    }

    /// The package of a style of the library, for "Show in Finder": the folder its image's folder is in.
    func packageURL(of style: NamedStyle) -> URL {
        library.imageDirectory(of: style).deletingLastPathComponent()
    }

    // MARK: - Changing

    /// "Use for New Projects": the style of `id`, or Toma's with `nil`.
    func setNewProjectsStyle(_ id: String?) {
        newProjectsStyleID = id
        var saved = settings.settings
        saved.newProjectsStyleID = id
        settings.settings = saved
    }

    /// Saves `style` (a new one, or over the one of its id), its image read from `package`.
    func save(_ style: NamedStyle, imageFrom package: ProjectPackage?) async throws {
        let library = library
        try await reloading { try await library.save(style, imageFrom: package) }
    }

    func rename(_ id: String, to name: String) async throws {
        let library = library
        try await reloading { try await library.rename(id: id, to: name) }
    }

    /// A copy of `style`, named «<name> copy» (or «<name> copy 2»…); the copy.
    func duplicate(_ style: NamedStyle) async throws -> NamedStyle {
        let library = library
        let name = StyleMenu.copyName(
            of: style.name, existing: styles.map(\.name),
            copy: { String(localized: "\($0) copy", comment: "The name of a copy") },
            numbered: { String(localized: "\($0) copy \($1)", comment: "The name of a copy when «… copy» is taken") })
        return try await reloading { try await library.duplicate(id: style.id, name: name) }
    }

    /// Gives the style of `id` to the macOS Trash; if new projects took it, they take Toma's style from now on.
    func delete(_ id: String) async throws {
        let library = library
        try await reloading { try await library.delete(id: id) }
        if newProjectsStyleID == id { setNewProjectsStyle(nil) }
    }

    /// `body`'s change of the library, which is read again after it, whether it went through or not.
    private func reloading<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do {
            let result = try await body()
            await reload()
            return result
        } catch {
            await reload()
            throw error
        }
    }

    /// Copies the `.tomastyle` at `url` into the library, unless it is one of its packages.
    func importStyle(_ url: URL) async -> StyleImportOutcome {
        await launched.value
        let directory = library.directory
        if await Task.detached(operation: { StyleMenu.isInLibrary(url, directory: directory) }).value { return .alreadyInLibrary }
        do {
            let style = try await library.importPackage(url)
            await reload()
            return .added(style)
        } catch StyleLibraryError.damaged {
            return .damaged
        } catch {
            Self.logger.error("Cannot import the style \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    /// `.tomastyle` packages opened from Finder: each is imported, and an alert says how it went.
    func openFromFinder(_ urls: [URL]) {
        Task {
            for url in urls {
                let outcome = await importStyle(url)
                guard let text = Self.text(outcome) else { continue }
                let alert = NSAlert()
                alert.messageText = text
                if case .added = outcome {} else { alert.alertStyle = .warning }
                NSApp.activate()
                alert.runModal()
            }
        }
    }

    /// What the app says of an import; nothing for a package of the library.
    static func text(_ outcome: StyleImportOutcome) -> String? {
        switch outcome {
        case let .added(style): String(localized: "Style “\(style.name)” was added.", comment: "A .tomastyle was imported")
        case .damaged: String(localized: "Couldn't import the style: the file is damaged.")
        case .failed: String(localized: "Couldn't import the style.", comment: "Importing a .tomastyle failed on the disk")
        case .alreadyInLibrary: nil
        }
    }
}
