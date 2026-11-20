// SPDX-License-Identifier: GPL-3.0-or-later
import Export
import Foundation
import ProjectAPI
import ProjectFormat
import Sharing

/// What `toma share` and the `share` tool use that a test replaces: the secret's store (the Keychain), the settings the
/// app saved, the service (its URL session) and, if given, how the video is made.
struct ShareSetup: Sendable {
    var secrets: any SecretStore
    var settings: @Sendable () -> SavedShareSettings
    var service: @Sendable () -> ShareService
    /// `nil`: `ShareRun.makeVideo(of:highQuality:)`, the export of the project as Toma exports it.
    var makeVideo: ShareJob.MakeVideo?

    /// The Keychain, the app's saved Settings ▸ Share and the real network (an ephemeral session).
    static let live = app(suite: ShareSettingsSource.appDomain, secrets: KeychainSecretStore())

    /// The settings saved in the defaults of `suite` (the app's domain, `recorderSettings`), the secrets of `secrets` and the real network.
    static func app(suite: String, secrets: any SecretStore) -> ShareSetup {
        ShareSetup(
            secrets: secrets, settings: { ShareSettingsSource.read(UserDefaults(suiteName: suite)) },
            service: { ShareService(session: S3Client.ephemeralSession()) }, makeVideo: nil)
    }
}

/// What `toma share` and the `share` tool have in common (plan 5a, Task S5): share a project with the person's saved
/// Settings ▸ Share and the secret of the Keychain, list its links, delete one, and say what went wrong as an `APIError`.
/// Nothing here connects unless asked to share or delete.
enum ShareRun {
    /// Shares the project at `package` (opened for reading: nothing in it changes but `shares.json`): `ShareInputs` of its
    /// document ("Intro" opens the chapters), then `ShareJob.run`. `progress` says where it is, from 0 to 1.
    /// - Throws: `APIError` for what is refused or fails (`notAvailable` without settings or a secret, `exportFailed`,
    ///   `uploadFailed`…), `CancellationError` if the task is cancelled (what was uploaded is removed first).
    @MainActor static func share(
        package: URL, setup: ShareSetup, environment: APIEnvironment,
        progress: @escaping @Sendable (ShareProgress) -> Void
    ) async throws -> ShareRecord {
        let saved = setup.settings()
        let project = try await TomaProject.open(package, mode: .read, environment: environment)
        do {
            let record = try await run(project, saved: saved, setup: setup, progress: progress)
            await project.close()
            return record
        } catch {
            await project.close()
            throw apiError(error)
        }
    }

    @MainActor private static func run(
        _ project: TomaProject, saved: SavedShareSettings, setup: ShareSetup,
        progress: @escaping @Sendable (ShareProgress) -> Void
    ) async throws -> ShareRecord {
        let loaded = project.project, document = project.document
        let name = project.url.deletingPathExtension().lastPathComponent
        // Reads events from the disk: not on this actor.
        let inputs = try await Task.detached {
            try ShareInputs.make(
                project: loaded, document: document, recorded: ShareInputs.recordedMarkers(of: loaded), projectName: name,
                introTitle: "Intro")
        }.value
        let makeVideo = setup.makeVideo ?? Self.makeVideo(of: project, highQuality: saved.highQuality)
        return try await ShareJob.run(
            package: loaded.package, inputs: inputs, preferences: saved.preferences, secrets: setup.secrets,
            service: setup.service(), makeVideo: makeVideo, progress: progress)
    }

    /// The share's video: the project's document exported as H.264 MP4 with `TomaProject.export` (the same preparation
    /// and exporter as the app's, with the environment's workers), never reusing an earlier export.
    @MainActor static func makeVideo(of project: TomaProject, highQuality: Bool) -> ShareJob.MakeVideo {
        let language = chapterLanguage(of: project.document)
        return { request, suggested, progress in
            let settings = exportSettings(for: request, highQuality: highQuality, language: language)
            _ = try await project.export(to: suggested, format: .video(settings), progress: progress)
            return suggested
        }
    }

    /// The settings of the share's video: `request`'s size, frame rate and chapters (H.264, 1080p by `ShareInputs`), at
    /// the quality Settings ▸ Export has.
    static func exportSettings(for request: ShareJob.VideoRequest, highQuality: Bool, language: String?) -> ExportSettings {
        ExportSettings(
            outputSize: request.outputSize, framesPerSecond: request.framesPerSecond, quality: highQuality ? .high : .standard,
            codec: .h264, chapters: request.chapters, chapterLanguage: request.chapters.isEmpty ? nil : language)
    }

    /// The language of the chapters' titles: the transcript's (its language alone), `nil` without a transcript.
    private static func chapterLanguage(of document: EditDocument) -> String? {
        guard let language = document.transcript?.language, !language.isEmpty else { return nil }
        return Locale.Language(identifier: language).languageCode?.identifier ?? language
    }

    // MARK: - List and delete

    /// The links of the package, newest first (`shares.json`); connects to nothing.
    static func list(package: URL) throws -> [ShareRecord] {
        do {
            return try ShareHistory(package: ProjectPackage(url: package)).records()
        } catch {
            throw apiError(error)
        }
    }

    /// Deletes the link `id` of the package from the storage and then from `shares.json`.
    /// - Throws: `APIError`: `refused` for an id the project does not have, `notAvailable` without settings or a secret.
    static func delete(id: String, package: URL, setup: ShareSetup) async throws {
        do {
            let handle = ProjectPackage(url: package)
            guard let record = try ShareHistory(package: handle).records().first(where: { $0.id == id }) else {
                throw APIError(.refused, "this project has no link “\(id)”: toma share --list shows them")
            }
            try await ShareJob.delete(
                record, package: handle, preferences: setup.settings().preferences, secrets: setup.secrets,
                service: setup.service())
        } catch {
            throw apiError(error)
        }
    }

    // MARK: - Errors

    /// `error` as the API says it, with no secret, header or URL in its words; a cancellation stays one.
    static func apiError(_ error: any Error) -> any Error {
        switch error {
        case let error as APIError:
            return error
        case is CancellationError, ShareError.cancelled:
            return CancellationError()
        case let error as ShareError:
            return describe(error)
        case let error as SecretStoreError:
            switch error {
            case let .keychain(status):
                return APIError(.notAvailable, "the Keychain would not give the secret key (status \(status)); share once from Toma ▸ Settings ▸ Share to allow it")
            case .notText:
                return APIError(.notAvailable, "the secret key in the Keychain is not text: save it again in Toma ▸ Settings ▸ Share")
            }
        case let error as POSIXError:
            return APIError(.refused, "the project's shares.json cannot be used: \(error.code.rawValue)")
        default:
            return APIError(.exportFailed, "the share failed: \(error)")
        }
    }

    private static func describe(_ error: ShareError) -> APIError {
        switch error {
        case let .notConfigured(problem):
            return APIError(.notAvailable, "Share is not set up: \(Self.describe(problem)). Open Toma ▸ Settings ▸ Share.")
        case let .authentication(code):
            return APIError(.refused, "the storage refused the credentials (\(code)): check the keys in Toma ▸ Settings ▸ Share")
        case .noSuchBucket:
            return APIError(.refused, "the bucket does not exist at this endpoint: check Toma ▸ Settings ▸ Share")
        case let .server(status, code):
            return APIError(.uploadFailed, "the storage answered \(status)\(code.map { " (\($0))" } ?? ""); what was uploaded was removed")
        case let .network(code):
            return APIError(.uploadFailed, "the storage could not be reached (network error \(code.rawValue)); what was uploaded was removed")
        case .clockSkew:
            return APIError(.uploadFailed, "the storage says this Mac's clock is off: set the date and time automatically")
        case let .publicURLNotServing(status):
            return APIError(.uploadFailed, "the public URL did not serve what was uploaded (status \(status))")
        case .otherStorage:
            return APIError(.refused, "this link is on another storage than the one Toma ▸ Settings ▸ Share has now: nothing was deleted")
        case .cancelled:
            return APIError(.uploadFailed, "cancelled")
        case .historyUnreadable:
            return APIError(.refused, "the project's shares.json cannot be read, so nothing was shared or changed: fix or remove the file")
        case .notSaved:
            return APIError(.uploadFailed, "the link could not be saved in the project's shares.json; what was uploaded was removed")
        case let .notSavedNorRemoved(bucket, folder):
            return APIError(.uploadFailed, "the link could not be saved and what was uploaded could not be removed: it may still be in the bucket “\(bucket)” at “\(folder)”; remove it there by hand")
        }
    }

    private static func describe(_ problem: ShareConfigurationProblem) -> String {
        switch problem {
        case .missingEndpoint: "no endpoint"
        case .invalidEndpoint: "the endpoint is not an http(s)://host address"
        case .insecureEndpoint: "the endpoint is http:// to a host that is not local"
        case .missingBucket: "no bucket"
        case .invalidBucket: "the bucket's name is not valid"
        case .invalidPrefix: "the folder prefix is not valid"
        case .missingAccessKey: "no Access Key ID"
        case .missingSecret: "no secret key in the Keychain"
        case .invalidPublicURL: "the public URL is not valid"
        case .insecurePublicURL: "the public URL is http:// to a host that is not local"
        case .invalidRegion: "the region is not valid"
        case .invalidAccessKey: "the Access Key ID is not valid"
        }
    }
}

/// What `toma share --json` and the `share` tool give for a link: the link, whether it is public, when a signed one
/// stops working (`null` for a public one), its size and when it was made.
struct ShareOutput: Encodable, Equatable {
    var id: String
    var url: String
    var `public`: Bool
    var expiresAt: Date?
    var bytes: Int64
    var createdAt: Date

    init(_ record: ShareRecord) {
        id = record.id
        url = record.url
        `public` = record.isPublic
        expiresAt = record.expiresAt
        bytes = record.bytes
        createdAt = record.createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, url, `public`, expiresAt, bytes, createdAt }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(`public`, forKey: .public)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// What the link says about its end, in the Mac's time: `Public link.` or `Link expires <date>.`.
    static func lifetime(_ record: ShareRecord) -> String {
        guard let expiresAt = record.expiresAt else { return "Public link." }
        return "Link expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))."
    }
}

/// The result of `share` with `list`: `{"shares": [...]}`.
struct ShareListOutput: Encodable {
    var shares: [ShareOutput]
}
