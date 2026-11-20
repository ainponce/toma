// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat
import RecorderKitTestSupport
import Sharing
import Synchronization
import Testing
@testable import toma

/// `toma share` and the `share` tool (plan 5a, Task S5): usage errors, the schema, listing without the network, what
/// "not set up" does, where the settings come from, the errors in words and one whole share against a network that is
/// down. No test reaches a real network or the Keychain: the secret is `InMemorySecretStore` and the sessions are fakes.
@Suite struct ShareCommandTests {
    static let accessKey = "AKIDEXAMPLE"
    static let linkID = "k3m7q2x4za"
    static let metal = MetalCondition.isAvailable || MetalCondition.isRequired

    static var configured: SharePreferences {
        SharePreferences(
            provider: .s3, endpoint: "https://s3.us-east-1.amazonaws.com", region: "us-east-1", bucket: "demo", prefix: "toma/",
            accessKeyID: accessKey, publicBaseURL: "", linkDays: 7)
    }

    /// A setup whose network is `FailingNetwork`, which counts its requests; `exports` counts the videos asked for.
    static func setup(
        preferences: SharePreferences = configured, secret: String? = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        highQuality: Bool = false, makeVideo: ShareJob.MakeVideo? = nil
    ) -> ShareSetup {
        let secrets = InMemorySecretStore(secret.map { [accessKey: $0] } ?? [:])
        return ShareSetup(
            secrets: secrets, settings: { SavedShareSettings(preferences: preferences, highQuality: highQuality) },
            service: { ShareService(session: FailingNetwork.session) }, makeVideo: makeVideo)
    }

    static func record(_ id: String, at seconds: Double, expires: Double? = nil) -> ShareRecord {
        ShareRecord(
            id: id, url: "https://example.com/toma/\(id)/index.html", createdAt: Date(timeIntervalSince1970: seconds),
            expiresAt: expires.map { Date(timeIntervalSince1970: $0) }, bytes: 1234, documentHash: "h",
            endpoint: "https://s3.us-east-1.amazonaws.com", bucket: "demo", folder: "toma/\(id)/")
    }

    // MARK: - The command's usage

    @Test func listAndDeleteAreExclusive() async throws {
        let status = await Toma.run(["share", "Fixture.toma", "--list", "--delete", Self.linkID])
        #expect(status == 2)
        #expect(throws: (any Error).self) { try ShareCommand.parse(["Fixture.toma", "--list", "--delete", Self.linkID]) }
    }

    @Test func deleteNeedsAShareID() async throws {
        #expect(await Toma.run(["share", "Fixture.toma", "--delete", "nada"]) == 2)
        // Not base 32: a 9, a 0, an upper-case letter, the wrong length.
        for id in ["k3m7q2x9za", "k3m7q2x0za", "K3M7Q2X4ZA", "k3m7q2x4z"] {
            #expect(await Toma.run(["share", "Fixture.toma", "--delete", id]) == 2, "\(id)")
        }
        #expect(throws: Never.self) { try ShareCommand.parse(["Fixture.toma", "--delete", Self.linkID]) }
    }

    @Test func shareIsInTheSubcommandsAndTheCatalog() {
        #expect(Toma.configuration.subcommands.contains { $0 == ShareCommand.self })
        #expect(MCPToolCatalog.all.map(\.name).last == "share")
    }

    // MARK: - The tool

    @Test func shareToolSchemaNeedsAProject() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let mcp = MCPHarness(in: dir, tools: [ShareTool(setup: Self.setup())])
            let list = try await mcp.request("tools/list", id: .integer(1))
            let tool = try #require(list["result"]?["tools"]?.arrayValue?.first)
            #expect(tool["name"] == .string("share"))
            #expect(tool["inputSchema"]?["required"] == .array([.string("project")]))
            #expect(tool["inputSchema"]?["additionalProperties"] == .bool(false))
            #expect(tool["inputSchema"]?["properties"]?["list"]?["type"] == .string("boolean"))
            #expect(tool["description"]?.stringValue?.contains("Settings") == true)
            func code(_ arguments: [String: JSONValue], _ id: Int64) async throws -> JSONValue? {
                try await mcp.call("share", arguments, id: id)["structuredContent"]?["error"]?["code"]
            }
            #expect(try await code([:], 2) == .string("invalidCommand"))
            #expect(try await code(["project": .string(url.path), "delete": .string(Self.linkID)], 3) == .string("invalidCommand"))
            #expect(try await code(["project": .string(url.path), "list": .string("yes")], 4) == .string("invalidCommand"))
            #expect(try await code(["project": .string("Sub/../Fixture.toma")], 5) == .string("notAProject"))
            #expect(try await code(["project": .string(dir.path)], 6) == .string("notAProject"))
        }
    }

    @Test func listingReadsTheProjectWithoutTheNetwork() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let history = ShareHistory(package: ProjectPackage(url: url))
            try history.append(Self.record("aaaaaaaaaa", at: 1_700_000_000))
            try history.append(Self.record("bbbbbbbbbb", at: 1_700_000_100, expires: 1_700_600_000))
            FailingNetwork.requests.withLock { $0 = 0 }
            let mcp = MCPHarness(in: dir, tools: [ShareTool(setup: Self.setup(secret: nil))])
            let result = try await mcp.call("share", ["project": .string(url.path), "list": .bool(true)], id: 1)
            #expect(result["isError"] == .bool(false))
            let shares = try #require(result["structuredContent"]?["shares"]?.arrayValue)
            #expect(shares.map { $0["id"]?.stringValue } == ["bbbbbbbbbb", "aaaaaaaaaa"])
            #expect(shares[0]["public"] == .bool(false))
            #expect(shares[0]["expiresAt"]?.stringValue != nil)
            #expect(shares[1]["public"] == .bool(true))
            #expect(shares[1]["expiresAt"] == .null)
            #expect(shares[1]["bytes"] == .integer(1234))
            #expect(Set(shares[1].objectValue?.keys.map { $0 } ?? []) == ["id", "url", "public", "expiresAt", "bytes", "createdAt"])
            #expect(FailingNetwork.requests.withLock { $0 } == 0)
            // And a project with none.
            let empty = try await CLIFixtures.package(in: dir, name: "Empty")
            let none = try await mcp.call("share", ["project": .string(empty.path), "list": .bool(true)], id: 2)
            #expect(none["structuredContent"]?["shares"] == .array([]))
        }
    }

    @Test func notConfiguredIsNotAvailable() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let exports = Mutex(0)
            let make: ShareJob.MakeVideo = { _, suggested, _ in
                exports.withLock { $0 += 1 }
                return suggested
            }
            // Nothing saved at all; then settings without a secret in the Keychain.
            for setup in [Self.setup(preferences: SharePreferences(), makeVideo: make), Self.setup(secret: nil, makeVideo: make)] {
                let mcp = MCPHarness(in: dir, tools: [ShareTool(setup: setup)])
                let result = try await mcp.call("share", ["project": .string(url.path)], id: 1)
                #expect(result["isError"] == .bool(true))
                #expect(result["structuredContent"]?["error"]?["code"] == .string("notAvailable"))
                #expect(result["structuredContent"]?["error"]?["message"]?.stringValue?.contains("Settings") == true)
            }
            #expect(exports.withLock { $0 } == 0)
            #expect(!FileManager.default.fileExists(atPath: url.appending(path: ShareHistory.fileName).path))
        }
    }

    @Test func deletingAnUnknownIDIsRefused() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            FailingNetwork.requests.withLock { $0 = 0 }
            await #expect(throws: APIError.self) {
                try await ShareRun.delete(id: Self.linkID, package: url, setup: Self.setup())
            }
            do {
                try await ShareRun.delete(id: Self.linkID, package: url, setup: Self.setup())
            } catch let error as APIError {
                #expect(error.code == .refused)
            }
            #expect(FailingNetwork.requests.withLock { $0 } == 0)
        }
    }

    // MARK: - Settings and errors

    @Test func settingsComeFromTheApp() throws {
        let suite = "dev.toma.TomaTests.share-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let json = """
            {"share": {"provider": "b2", "endpoint": "https://s3.us-west-004.backblazeb2.com", "region": "us-west-004", \
            "bucket": "clips", "prefix": "tm/", "accessKeyID": "AKIAIOSFODNN7EXAMPLE", "linkDays": 1}, \
            "export": {"highQuality": true}}
            """
        defaults.set(Data(json.utf8), forKey: ShareSettingsSource.settingsKey)
        let setup = ShareSetup.app(suite: suite, secrets: InMemorySecretStore())
        let saved = setup.settings()
        #expect(saved.highQuality)
        #expect(saved.preferences.provider == .b2)
        #expect(saved.preferences.bucket == "clips")
        #expect(saved.preferences.accessKeyID == "AKIAIOSFODNN7EXAMPLE")
        #expect(saved.preferences.linkDays == 1)
        // The quality of the app's export sheet is the share's video's.
        let request = ShareJob.VideoRequest(outputSize: [1920, 1080], framesPerSecond: 30, chapters: [], documentHash: "h")
        #expect(ShareRun.exportSettings(for: request, highQuality: saved.highQuality, language: nil).quality == .high)
        #expect(ShareRun.exportSettings(for: request, highQuality: false, language: nil).quality == .standard)
        let settings = ShareRun.exportSettings(for: request, highQuality: false, language: "es")
        #expect(settings.codec == .h264 && settings.outputSize == [1920, 1080] && settings.framesPerSecond == 30)
        // Without chapters the file has no chapter language.
        #expect(settings.chapterLanguage == nil)
    }

    @Test func shareErrorsAreClearAndKeepNoSecrets() {
        let cases: [(ShareError, APIErrorCode, String)] = [
            (.notConfigured(.missingBucket), .notAvailable, "Settings"),
            (.notConfigured(.missingSecret), .notAvailable, "Keychain"),
            (.authentication(code: "SignatureDoesNotMatch"), .refused, "SignatureDoesNotMatch"),
            (.noSuchBucket, .refused, "bucket"),
            (.otherStorage, .refused, "another storage"),
            (.server(status: 500, code: "InternalError"), .uploadFailed, "500"),
            (.network(.timedOut), .uploadFailed, "network"),
            (.clockSkew, .uploadFailed, "clock"),
            (.publicURLNotServing(status: 404), .uploadFailed, "404"),
            (.historyUnreadable, .refused, "shares.json"),
            (.notSaved, .uploadFailed, "removed"),
            (.notSavedNorRemoved(bucket: "demo", folder: "toma/k3m7q2x4za/"), .uploadFailed, "toma/k3m7q2x4za/"),
        ]
        for (error, code, word) in cases {
            let mapped = ShareRun.apiError(error) as? APIError
            #expect(mapped?.code == code, "\(error)")
            #expect(mapped?.message.contains(word) == true, "\(error): \(mapped?.message ?? "")")
        }
        #expect(ShareRun.apiError(ShareError.cancelled) is CancellationError)
        #expect((ShareRun.apiError(SecretStoreError.keychain(-25293)) as? APIError)?.code == .notAvailable)
        #expect((ShareRun.apiError(SecretStoreError.notText) as? APIError)?.code == .notAvailable)
        let passed = APIError(.outOfRange, "too short")
        #expect(ShareRun.apiError(passed) as? APIError == passed)
    }

    @Test func uploadFailedIsAnAPIErrorCode() throws {
        #expect(APIErrorCode.allCases.last == .uploadFailed)
        #expect(APIErrorCode.uploadFailed.rawValue == "uploadFailed")
        #expect(CLI.exitCode(.uploadFailed) == 1)
    }

    /// `toma share --list` as a process: the links as a JSON array or lines of text, without connecting; a project with
    /// none prints nothing (or `[]`); an id that is not one is a usage error (2).
    @Test func listingAsAProcess() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let history = ShareHistory(package: ProjectPackage(url: url))
            try history.append(Self.record("aaaaaaaaaa", at: 1_700_000_000))
            let json = try await CLIFixtures.toma(["share", url.path, "--list", "--json"], in: dir)
            #expect(json.status == 0, "\(json.stderr)")
            let rows = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [[String: Any]])
            #expect(rows.count == 1 && rows[0]["id"] as? String == "aaaaaaaaaa" && rows[0]["public"] as? Bool == true)
            let text = try await CLIFixtures.toma(["share", url.path, "--list"], in: dir)
            #expect(text.status == 0 && text.stdout.hasPrefix("aaaaaaaaaa  https://example.com/toma/aaaaaaaaaa/index.html  Public link."))
            let usage = try await CLIFixtures.toma(["share", url.path, "--list", "--delete", Self.linkID, "--json"], in: dir)
            #expect(usage.status == 2 && usage.errorCode == "invalidCommand")
            let missing = try await CLIFixtures.toma(["share", dir.appending(path: "No.toma").path, "--list", "--json"], in: dir)
            #expect(missing.status == 1 && missing.errorCode == "notAProject")
        }
    }

    // MARK: - A whole share

    /// The export and the poster are real; the network is down: the upload fails with `uploadFailed`, nothing is left in
    /// the temporary folder and `shares.json` is not written. Progress went through exporting.
    @Test(.enabled(if: metal)) func shareExportsThenFailsOnADownNetwork() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            FailingNetwork.requests.withLock { $0 = 0 }
            let phases = Mutex<[ShareProgress.Phase]>([])
            let setup = Self.setup(makeVideo: nil)
            let environment = CLIFixtures.environment(in: dir)
            do {
                _ = try await ShareRun.share(package: url, setup: setup, environment: environment) { progress in
                    phases.withLock { $0.append(progress.phase) }
                }
                Issue.record("the share cannot succeed against a network that is down")
            } catch let error as APIError {
                #expect(error.code == .uploadFailed, "\(error)")
            }
            #expect(phases.withLock { $0 }.contains(.exporting))
            #expect(FailingNetwork.requests.withLock { $0 } > 0)
            #expect(!FileManager.default.fileExists(atPath: url.appending(path: ShareHistory.fileName).path))
            // The project is as it was, and no lock is left.
            #expect(!FileManager.default.fileExists(atPath: url.appending(path: "edit.lock").path))
        }
    }

    /// With a stand-in for the export the job still gets the project's inputs: its name for the title and the chapters.
    @Test func shareGivesTheExportTheProjectsInputs() async throws {
        try await withTemporaryDirectory { dir in
            let url = try await CLIFixtures.package(in: dir)
            let seen = Mutex<ShareJob.VideoRequest?>(nil)
            let make: ShareJob.MakeVideo = { request, _, _ in
                seen.withLock { $0 = request }
                throw CancellationError()
            }
            do {
                _ = try await ShareRun.share(
                    package: url, setup: Self.setup(makeVideo: make), environment: CLIFixtures.environment(in: dir)
                ) { _ in }
                Issue.record("it stops at the export")
            } catch is CancellationError {}
            let request = try #require(seen.withLock { $0 })
            #expect(request.framesPerSecond > 0)
            #expect(request.outputSize.y == 1080 || request.outputSize.x == 1080)
            #expect(request.documentHash.count == 64)
        }
    }
}

/// A `URLSession` whose every request fails as if the network were down, counting them.
final class FailingNetwork: URLProtocol, @unchecked Sendable {
    static let requests = Mutex(0)

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingNetwork.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
