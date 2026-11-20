// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import Observation
import Sharing
import os

/// Settings ▸ Share (plan 5a, Task S4, decision 14; design §8.1 and §8.4): where Share uploads and how long its link
/// lasts. Each change is saved at once (`SettingsStore`); choosing a service fills in its template and changing the
/// region moves a template's endpoint (`ShareRules`). The secret key goes to the Keychain under the Access Key ID
/// (`SharePreferences.secretAccount`) once its field is confirmed or left, and is never shown back; a new Access Key ID
/// takes the secret typed with it and the old one's is deleted. Nothing connects but "Test Connection".
@MainActor @Observable
final class SettingsShareModel {
    /// "Test Connection": not tried since the last change, trying, or how it went.
    enum Test: Equatable {
        case idle, testing, succeeded
        case failed(String)
    }

    /// The fields that have a problem of their own (`ShareConfigurationProblem`).
    enum Field: Hashable {
        case endpoint, region, bucket, prefix, accessKey, secret, publicURL
    }

    private(set) var preferences: SharePreferences
    /// The secret key as typed, until it is saved: it is never read back from the Keychain.
    var secretDraft = ""
    /// The Keychain has the secret of the Access Key ID saved (`savedAccount`).
    private(set) var hasSecret = false
    /// Why the Keychain could not save, delete or read the secret, or why the one typed waits.
    private(set) var secretProblem: String?
    private(set) var test: Test = .idle

    @ObservationIgnored private let save: (SharePreferences) -> Void
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let tester: @Sendable (SharePreferences, String) async throws -> Void
    /// The Access Key ID the Keychain's secret is saved under: as read, or as last confirmed.
    @ObservationIgnored private var savedAccount: String
    /// The Keychain's work, one after another, off the main thread.
    @ObservationIgnored private var keychain: Task<Void, Never>?
    @ObservationIgnored private var testing: Task<Void, Never>?

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Share")

    /// Settings ▸ Share of `store`, with the secret in `secrets` (the Keychain).
    convenience init(store: SettingsStore, secrets: any SecretStore) {
        self.init(
            preferences: store.settings.share, secrets: secrets,
            save: { preferences in
                var settings = store.settings
                settings.share = preferences
                store.settings = settings
            },
            tester: { preferences, secret in
                try await EditorShare.service().testConnection(preferences: preferences, secret: secret)
            })
    }

    init(
        preferences: SharePreferences, secrets: any SecretStore, save: @escaping (SharePreferences) -> Void,
        tester: @escaping @Sendable (SharePreferences, String) async throws -> Void
    ) {
        self.preferences = preferences
        self.secrets = secrets
        self.save = save
        self.tester = tester
        savedAccount = preferences.secretAccount
    }

    /// The pane, made up for the screenshots in Debug, or Settings ▸ Share with the Keychain.
    static func make() -> SettingsShareModel {
        #if DEBUG
        if let showcase = showcase() { return showcase }
        #endif
        return SettingsShareModel(store: SettingsStore(), secrets: KeychainSecretStore())
    }

    // MARK: - The fields

    func setProvider(_ provider: ShareProvider) {
        change(ShareRules.choosing(provider, in: preferences))
    }

    func setEndpoint(_ endpoint: String) {
        var changed = preferences
        changed.endpoint = endpoint
        change(changed)
    }

    func setRegion(_ region: String) {
        change(ShareRules.changingRegion(region, in: preferences))
    }

    func setBucket(_ bucket: String) {
        var changed = preferences
        changed.bucket = bucket
        change(changed)
    }

    func setPrefix(_ prefix: String) {
        var changed = preferences
        changed.prefix = prefix
        change(changed)
    }

    /// The Access Key ID as typed; its secret follows it once the field is confirmed or left (`commitAccessKey`).
    func setAccessKeyID(_ accessKeyID: String) {
        var changed = preferences
        changed.accessKeyID = accessKeyID
        change(changed)
    }

    func setPublicBaseURL(_ url: String) {
        var changed = preferences
        changed.publicBaseURL = url
        change(changed)
    }

    func setLinkDays(_ days: Int) {
        var changed = preferences
        changed.linkDays = min(max(days, 1), 7)
        change(changed)
    }

    /// Whether the link expires: without a public URL.
    var hasPublicURL: Bool {
        !preferences.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Everything that keeps the settings from making a configuration (the secret typed counts as there).
    var problems: [ShareConfigurationProblem] {
        ShareConfiguration.problems(in: preferences, hasSecret: hasSecret || !secretDraft.isEmpty)
    }

    /// What is wrong with what was written in `field` (not what is missing: that is said once, by "Test Connection").
    func problem(of field: Field) -> ShareConfigurationProblem? {
        problems.first { Self.field(of: $0) == field && !Self.isMissing($0) }
    }

    /// The first thing missing, in the order of the fields: what "Test Connection" waits for.
    var missing: ShareConfigurationProblem? {
        problems.first(where: Self.isMissing)
    }

    // MARK: - The secret

    /// Reads whether the Keychain has the secret of the Access Key ID, off the main thread: the pane appeared.
    func load() {
        let account = savedAccount, secrets = secrets
        enqueue { [weak self] in
            let result = Result { () throws -> Bool in
                account.isEmpty ? false : !(try secrets.secret(for: account) ?? "").isEmpty
            }
            await self?.loaded(result)
        }
    }

    private func loaded(_ result: Result<Bool, any Error>) {
        switch result {
        case .success(let has):
            hasSecret = has
        case .failure(let error):
            Self.logger.error("Cannot read the share secret: \(String(describing: error), privacy: .public)")
            secretProblem = ShareTexts.describe(error)
        }
    }

    /// The secret typed, saved to the Keychain under the Access Key ID (the field was confirmed or left); without an
    /// Access Key ID yet, it waits for one.
    func commitSecret() {
        commitAccessKey()
        let secret = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return }
        let account = preferences.secretAccount
        guard !account.isEmpty else {
            secretProblem = String(
                localized: "Enter the Access Key ID to save the secret key.",
                comment: "Settings ▸ Share: a secret key typed before its Access Key ID")
            return
        }
        secretDraft = ""
        let secrets = secrets
        enqueue { [weak self] in
            let result = Result { try secrets.setSecret(secret, for: account) }
            await self?.saved(result, has: true)
        }
    }

    /// A new Access Key ID confirmed (its field was confirmed or left): the secret typed is saved under it, and the old
    /// one's secret is deleted from the Keychain.
    func commitAccessKey() {
        let account = preferences.secretAccount, old = savedAccount
        guard account != old else { return }
        savedAccount = account
        let secret = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let saving = account.isEmpty || secret.isEmpty ? nil : secret
        if saving != nil { secretDraft = "" }
        hasSecret = false
        let secrets = secrets
        enqueue { [weak self] in
            let result = Result {
                if let saving { try secrets.setSecret(saving, for: account) }
                if !old.isEmpty { try secrets.setSecret(nil, for: old) }
            }
            await self?.saved(result, has: saving != nil)
        }
    }

    /// "Delete Key": the secret of the Access Key ID deleted from the Keychain.
    func deleteSecret() {
        let account = savedAccount, secrets = secrets
        secretDraft = ""
        enqueue { [weak self] in
            let result = Result { if !account.isEmpty { try secrets.setSecret(nil, for: account) } }
            await self?.saved(result, has: false)
        }
    }

    private func saved(_ result: Result<Void, any Error>, has: Bool) {
        switch result {
        case .success:
            hasSecret = has
            secretProblem = nil
            test = .idle
        case .failure(let error):
            Self.logger.error("Cannot change the share secret: \(String(describing: error), privacy: .public)")
            if case let SecretStoreError.keychain(status) = error {
                secretProblem = String(
                    format: String(
                        localized: "Couldn't change the secret key in the Keychain (error %lld).",
                        comment: "Settings ▸ Share: saving or deleting the secret key in the Keychain failed"),
                    Int(status))
            } else {
                secretProblem = ShareTexts.describe(error)
            }
        }
    }

    // MARK: - Test Connection

    /// "Test Connection" (decision 12): the fields confirmed, then a small file uploaded and deleted (and, with a public
    /// URL, read from it).
    func testConnection() {
        guard test != .testing else { return }
        commitSecret()
        commitAccessKey()
        let preferences = preferences, account = preferences.secretAccount, secrets = secrets, tester = tester
        let before = keychain
        test = .testing
        testing = Task {
            await before?.value
            do {
                let secret = try await Task.detached { try secrets.secret(for: account) }.value
                guard let secret, !secret.isEmpty else { throw ShareError.notConfigured(.missingSecret) }
                try await tester(preferences, secret)
                guard self.preferences == preferences else { return }
                test = .succeeded
            } catch {
                Self.logger.error("Test Connection failed: \(String(describing: error), privacy: .public)")
                guard self.preferences == preferences else { return }
                test = .failed(ShareTexts.describe(error))
            }
        }
    }

    // MARK: - Private

    /// `preferences` changed: saved at once; what "Test Connection" said is of the settings before.
    private func change(_ changed: SharePreferences) {
        guard changed != preferences else { return }
        preferences = changed
        save(changed)
        if test != .testing { test = .idle }
    }

    /// `work` after the Keychain's work before it, off the main thread.
    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let before = keychain
        keychain = Task.detached {
            await before?.value
            await work()
        }
    }

    private static func field(of problem: ShareConfigurationProblem) -> Field {
        switch problem {
        case .missingEndpoint, .invalidEndpoint, .insecureEndpoint: .endpoint
        case .invalidRegion: .region
        case .missingBucket, .invalidBucket: .bucket
        case .invalidPrefix: .prefix
        case .missingAccessKey, .invalidAccessKey: .accessKey
        case .missingSecret: .secret
        case .invalidPublicURL, .insecurePublicURL: .publicURL
        }
    }

    private static func isMissing(_ problem: ShareConfigurationProblem) -> Bool {
        switch problem {
        case .missingEndpoint, .missingBucket, .missingAccessKey, .missingSecret: true
        default: false
        }
    }

    #if DEBUG
    /// `-TomaShowcase settings share[-new|-problems|-tested|-failed]`: the pane made up, with an example Access Key ID of
    /// AWS's documentation and a secret in memory; nothing is saved, the Keychain is not touched and "Test Connection"
    /// connects to nothing.
    private static func showcase() -> SettingsShareModel? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TomaShowcase"), index + 2 < arguments.count,
            arguments[index + 1] == "settings", arguments[index + 2].hasPrefix("share")
        else { return nil }
        let variant = arguments[index + 2]
        let account = "AKIAIOSFODNN7EXAMPLE"
        var preferences = SharePreferences(
            provider: .r2, endpoint: "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com", region: "auto",
            bucket: "toma-videos", prefix: "toma/", accessKeyID: account)
        var secrets: [String: String] = [account: "showcase"]
        switch variant {
        case "share-new":
            preferences = SharePreferences()
            secrets = [:]
        case "share-problems":
            preferences = SharePreferences(
                provider: .other, endpoint: "http://storage.example.com", region: "US East", bucket: "mis videos",
                prefix: "toma/../", accessKeyID: account, publicBaseURL: "videos.example.com")
        case "share-tested":
            preferences.publicBaseURL = "https://videos.example.com"
        default:
            break
        }
        let fails = variant == "share-failed"
        let model = SettingsShareModel(
            preferences: preferences, secrets: InMemorySecretStore(secrets), save: { _ in },
            tester: { _, _ in
                try await Task.sleep(for: .milliseconds(300))
                if fails { throw ShareError.authentication(code: "InvalidAccessKeyId") }
            })
        if variant == "share-tested" || fails {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                model.testConnection()
            }
        }
        return model
    }
    #endif
}
