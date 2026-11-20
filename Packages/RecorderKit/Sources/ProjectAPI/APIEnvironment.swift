// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ProjectFormat
import ProjectJobs
import Transcription

/// Where the project API finds what lives outside a package, and what it uses to make ids and tell the time: the app's
/// own folders by default (`standard`), so the API reads and writes the same caches, styles and music as the app; tests
/// give folders of their own.
public struct APIEnvironment: Sendable {
    /// The app the `create` lines of the edit log name: `toma` and `ProjectAPI.version`.
    public var app: AppInfo
    /// Every project's cache folder (`ProjectCaches.defaultRoot`): the same as the app's.
    public var cachesRoot: URL
    /// The music library's cache (`MusicLibrary.defaultRoot`).
    public var musicRoot: URL
    /// The user's named styles (`StyleLibrary.defaultDirectory`).
    public var stylesFolder: URL
    /// The library's folder, `~/Movies/Toma`.
    public var projectsFolder: URL
    /// The app's control socket, `~/Library/Application Support/dev.toma.Toma/control.sock`.
    public var controlSocket: URL
    public var now: @Sendable () -> Date
    /// A new id: `makeID("c-")` is `c-` and 8 random hex digits.
    public var makeID: @Sendable (String) -> String
    /// The transcription's engine: `SpeechTranscriberEngine` from macOS 26, none before.
    public var speech: (any SpeechEngine)?
    /// What cleans the voice before an export (`SystemVoiceIsolation`).
    public var isolator: any VoiceIsolating
    /// The edit journal's calls to the disk; the tests' fail.
    package var journalIO: EditJournalIO = .system

    public init(
        app: AppInfo, cachesRoot: URL, musicRoot: URL, stylesFolder: URL, projectsFolder: URL, controlSocket: URL,
        now: @escaping @Sendable () -> Date, makeID: @escaping @Sendable (String) -> String, speech: (any SpeechEngine)?,
        isolator: any VoiceIsolating
    ) {
        self.app = app
        self.cachesRoot = cachesRoot
        self.musicRoot = musicRoot
        self.stylesFolder = stylesFolder
        self.projectsFolder = projectsFolder
        self.controlSocket = controlSocket
        self.now = now
        self.makeID = makeID
        self.speech = speech
        self.isolator = isolator
    }

    /// The app's folders, each replaced by its variable when it is set (plan 4b decision 13): `TOMA_CACHES_ROOT`,
    /// `TOMA_MUSIC_ROOT`, `TOMA_STYLES`, `TOMA_PROJECTS_FOLDER` and `TOMA_CONTROL_SOCKET`. Ids are random and the clock is
    /// the system's.
    public static var standard: APIEnvironment {
        standard(variables: ProcessInfo.processInfo.environment)
    }

    /// `standard` with the variables `variables`.
    public static func standard(variables: [String: String]) -> APIEnvironment {
        func folder(_ name: String, _ fallback: URL, isDirectory: Bool = true) -> URL {
            guard let value = variables[name], !value.isEmpty else { return fallback }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: isDirectory)
        }
        let speech: (any SpeechEngine)?
        if #available(macOS 26, *) { speech = SpeechTranscriberEngine() } else { speech = nil }
        return APIEnvironment(
            app: AppInfo(name: "toma", version: ProjectAPI.version),
            cachesRoot: folder("TOMA_CACHES_ROOT", ProjectCaches.defaultRoot),
            musicRoot: folder("TOMA_MUSIC_ROOT", MusicLibrary.defaultRoot),
            stylesFolder: folder("TOMA_STYLES", StyleLibrary.defaultDirectory),
            projectsFolder: folder("TOMA_PROJECTS_FOLDER", defaultProjectsFolder),
            controlSocket: folder("TOMA_CONTROL_SOCKET", defaultControlSocket, isDirectory: false),
            now: { Date() },
            makeID: { prefix in prefix + String(format: "%08x", UInt32.random(in: .min ... .max)) },
            speech: speech, isolator: SystemVoiceIsolation())
    }

    /// `~/Movies/Toma`, as the app's `ProjectFolder.defaultURL(appName: "Toma")` has it (`AppSupport` is not a
    /// dependency of the API).
    public static var defaultProjectsFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        return movies.appendingPathComponent("Toma", isDirectory: true)
    }

    /// `~/Library/Application Support/dev.toma.Toma/control.sock` (design §6.4).
    public static var defaultControlSocket: URL {
        URL.applicationSupportDirectory.appending(path: "dev.toma.Toma", directoryHint: .isDirectory)
            .appending(path: "control.sock", directoryHint: .notDirectory)
    }

    /// What an edit session of the API takes: a new project gets Toma's style and camera (plan 4b decision 2).
    var editContext: EditContext {
        EditContext(
            app: app, cachesRoot: cachesRoot, defaultStyle: .toma, now: now, makeID: makeID, journalIO: journalIO,
            cameraLook: .newProjects)
    }
}
