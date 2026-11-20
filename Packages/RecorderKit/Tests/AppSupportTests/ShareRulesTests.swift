// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import Foundation
import Sharing
import Testing

@Suite struct ShareRulesTests {
    private static let chapters = [Chapter(start: 0, title: "Intro"), Chapter(start: 4_000_000_000, title: "Demo")]

    private static let request = ShareJob.VideoRequest(
        outputSize: [1920, 1080], framesPerSecond: 60, chapters: chapters, documentHash: "abc123")

    private static let export = RememberedExport(
        url: URL(fileURLWithPath: "/tmp/Demo.mp4"), documentHash: "abc123", outputSize: [1920, 1080], framesPerSecond: 60,
        codec: "h264", wholeVideo: true, bytes: 12_345, chapters: chapters)

    @Test func reuseNeedsTheSameDocumentAndSettings() {
        #expect(ShareRules.reusable(Self.export, for: Self.request, bytesNow: 12_345) == Self.export.url)
        // Nothing exported yet.
        #expect(ShareRules.reusable(nil, for: Self.request, bytesNow: 12_345) == nil)
        // Each one different is another video.
        var other = Self.export
        other.documentHash = "abc124"
        #expect(ShareRules.reusable(other, for: Self.request, bytesNow: 12_345) == nil)
        other = Self.export
        other.codec = "hevc"
        #expect(ShareRules.reusable(other, for: Self.request, bytesNow: 12_345) == nil)
        other = Self.export
        other.outputSize = [1280, 720]
        #expect(ShareRules.reusable(other, for: Self.request, bytesNow: 12_345) == nil)
        other = Self.export
        other.framesPerSecond = 30
        #expect(ShareRules.reusable(other, for: Self.request, bytesNow: 12_345) == nil)
        other = Self.export
        other.wholeVideo = false
        #expect(ShareRules.reusable(other, for: Self.request, bytesNow: 12_345) == nil)
        // Exported without "Chapters in the File": the shared video carries them.
        other = Self.export
        other.chapters = []
        #expect(ShareRules.reusable(other, for: Self.request, bytesNow: 12_345) == nil)
        // A project without chapters reuses a file without them.
        other.chapters = []
        var plain = Self.request
        plain.chapters = []
        #expect(ShareRules.reusable(other, for: plain, bytesNow: 12_345) == other.url)
    }

    @Test func aGoneOrChangedFileIsNotReused() {
        #expect(ShareRules.reusable(Self.export, for: Self.request, bytesNow: nil) == nil)
        #expect(ShareRules.reusable(Self.export, for: Self.request, bytesNow: 12_346) == nil)
        #expect(ShareRules.reusable(Self.export, for: Self.request, bytesNow: 0) == nil)
    }

    @Test func noteSaysPublicOrWhen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func record(expiresAt: Date?) -> ShareRecord {
            ShareRecord(
                id: "k3m7q2x4za", url: "https://videos.example.com/toma/k3m7q2x4za/index.html",
                createdAt: now.addingTimeInterval(-3600), expiresAt: expiresAt, bytes: 1, documentHash: "abc",
                endpoint: "https://example.r2.cloudflarestorage.com", bucket: "videos", folder: "toma/k3m7q2x4za/")
        }
        #expect(ShareRules.note(for: record(expiresAt: nil), now: now) == .permanent)
        let later = now.addingTimeInterval(86_400)
        #expect(ShareRules.note(for: record(expiresAt: later), now: now) == .expires(later))
        let earlier = now.addingTimeInterval(-60)
        #expect(ShareRules.note(for: record(expiresAt: earlier), now: now) == .expired(earlier))
        // At the very second it ends, it no longer works (`ShareRecord.hasExpired`).
        #expect(ShareRules.note(for: record(expiresAt: now), now: now) == .expired(now))
    }

    @Test func choosingAProviderFillsItsTemplate() {
        // R2 as it starts: S3's region and endpoint.
        let r2 = SharePreferences()
        let s3 = ShareRules.choosing(.s3, in: r2)
        #expect(s3.provider == .s3)
        #expect(s3.region == "us-east-1")
        #expect(s3.endpoint == "https://s3.us-east-1.amazonaws.com")
        // B2, from S3's template: B2's.
        let b2 = ShareRules.choosing(.b2, in: s3)
        #expect(b2.region == "us-west-004")
        #expect(b2.endpoint == "https://s3.us-west-004.backblazeb2.com")
        // Back to R2: its endpoint has the account in it, so it is left for the person (the field shows the template).
        let back = ShareRules.choosing(.r2, in: b2)
        #expect(back.region == "auto")
        #expect(back.endpoint == "")
        // MinIO with the endpoint empty: the local one.
        let minio = ShareRules.choosing(.minio, in: r2)
        #expect(minio.region == "us-east-1")
        #expect(minio.endpoint == "http://localhost:9000")
        // "Other": nothing to fill in.
        let other = ShareRules.choosing(.other, in: minio)
        #expect(other.endpoint == "")
        #expect(other.region == "us-east-1")
        // An endpoint written by hand stays; the region is the service's.
        var written = SharePreferences(endpoint: "https://0123abcd.r2.cloudflarestorage.com", bucket: "videos", accessKeyID: "AKIDEXAMPLE")
        written = ShareRules.choosing(.s3, in: written)
        #expect(written.endpoint == "https://0123abcd.r2.cloudflarestorage.com")
        #expect(written.region == "us-east-1")
        // So does one written by hand for MinIO on another port.
        let otherPort = ShareRules.choosing(.other, in: SharePreferences(provider: .minio, endpoint: "http://localhost:9100"))
        #expect(otherPort.endpoint == "http://localhost:9100")
        // The other fields are left as they are.
        #expect(written.bucket == "videos")
        #expect(written.accessKeyID == "AKIDEXAMPLE")
        // Choosing the same service changes nothing.
        let europe = SharePreferences(provider: .s3, endpoint: "https://s3.eu-west-1.amazonaws.com", region: "eu-west-1")
        #expect(ShareRules.choosing(.s3, in: europe) == europe)
    }

    @Test func changingTheRegionMovesATemplateEndpoint() {
        var s3 = ShareRules.choosing(.s3, in: SharePreferences())
        s3 = ShareRules.changingRegion("eu-west-1", in: s3)
        #expect(s3.region == "eu-west-1")
        #expect(s3.endpoint == "https://s3.eu-west-1.amazonaws.com")
        // Typed a letter at a time, through an empty region and one that is not a host's label yet.
        for region in ["", "s", "sa", "sa-", "sa-east-1"] { s3 = ShareRules.changingRegion(region, in: s3) }
        #expect(s3.region == "sa-east-1")
        #expect(s3.endpoint == "https://s3.sa-east-1.amazonaws.com")
        var b2 = ShareRules.choosing(.b2, in: SharePreferences())
        b2 = ShareRules.changingRegion("eu-central-003", in: b2)
        #expect(b2.endpoint == "https://s3.eu-central-003.backblazeb2.com")
        // An endpoint written by hand stays.
        let dualStack = SharePreferences(provider: .s3, endpoint: "https://s3.dualstack.us-east-1.amazonaws.com", region: "us-east-1")
        #expect(ShareRules.changingRegion("eu-west-1", in: dualStack).endpoint == dualStack.endpoint)
        // R2, MinIO and "Other" only change the region.
        let r2 = SharePreferences(endpoint: "https://0123abcd.r2.cloudflarestorage.com")
        let moved = ShareRules.changingRegion("eu", in: r2)
        #expect(moved.region == "eu")
        #expect(moved.endpoint == r2.endpoint)
        let minio = ShareRules.choosing(.minio, in: SharePreferences())
        #expect(ShareRules.changingRegion("eu-west-1", in: minio).endpoint == "http://localhost:9000")
    }
}
