// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import RecorderKitTestSupport
import Sharing
import Synchronization
import Testing

/// The S3 client against `FakeS3` (plan 5a, Review Focus 1–3): what reaches the storage is what was signed, a multipart
/// upload never stays half-done in the bucket, and the secret never leaves the process.
@Suite struct S3ClientTests {
    /// Small limits so a multipart upload needs a few hundred KiB, not 64 MiB.
    static let limits = S3Client.Limits(singlePut: 512 << 10, partSize: 256 << 10)

    /// A Mac's clock that moves one second each time it is read, so every signature has its own `x-amz-date`.
    final class TestClock: Sendable {
        private let date: Mutex<Date>
        init(_ start: Date = Date(timeIntervalSince1970: 1_795_000_000)) { date = Mutex(start) }
        @Sendable func now() -> Date {
            date.withLock {
                let now = $0
                $0 = $0.addingTimeInterval(1)
                return now
            }
        }
        var current: Date { date.withLock { $0 } }
    }

    /// The pauses between attempts, kept instead of slept.
    final class Pauses: Sendable {
        private let list = Mutex<[Duration]>([])
        @Sendable func pause(_ duration: Duration) async throws {
            list.withLock { $0.append(duration) }
            try Task.checkCancellation()
        }
        var all: [Duration] { list.withLock { $0 } }
    }

    final class ProgressLog: Sendable {
        private let list = Mutex<[Int64]>([])
        @Sendable func record(_ value: Int64) { list.withLock { $0.append(value) } }
        var all: [Int64] { list.withLock { $0 } }
    }

    struct Fixture {
        let fake: FakeS3
        let clock = TestClock()
        let pauses = Pauses()
        let client: S3Client

        init(fake: FakeS3 = FakeS3(), linkDays: Int = 7, limits: S3Client.Limits = S3ClientTests.limits) throws {
            self.fake = fake
            client = S3Client(
                configuration: try fake.configuration(linkDays: linkDays), session: fake.session, limits: limits,
                now: clock.now, pause: pauses.pause)
        }
    }

    static func bytes(_ count: Int, seed: UInt8 = 7) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    static func write(_ data: Data, in directory: URL, named name: String = "video.mp4") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func sha256(_ data: Data) -> String { FakeS3.hex(SHA256.hash(data: data)) }

    static func shareError(_ body: () async throws -> Void) async -> ShareError? {
        do {
            try await body()
            return nil
        } catch let error as ShareError {
            return error
        } catch {
            Issue.record("Not a ShareError: \(error)")
            return nil
        }
    }

    // MARK: - Uploads

    @Test func smallFileIsOneSignedPut() async throws {
        let fixture = try Fixture()
        let data = Self.bytes(1024)
        try await withTemporaryDirectory { directory in
            let file = try Self.write(data, in: directory)
            let sent = try await fixture.client.upload(file: file, key: "toma/x/video.mp4", contentType: "video/mp4", progress: nil)
            #expect(sent == 1024)
        }
        let requests = fixture.fake.requests
        #expect(requests.count == 1)
        let put = try #require(requests.first)
        #expect(put.method == "PUT" && put.path == "/bucket/toma/x/video.mp4" && put.query == nil)
        #expect(put.headers["x-amz-content-sha256"] == Self.sha256(data))
        #expect(put.headers["content-type"] == "video/mp4")
        #expect(put.signatureMatches)
        #expect(put.headers["authorization"]?.contains("SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date,") == true)
        #expect(fixture.fake.object(at: "/bucket/toma/x/video.mp4") == FakeS3.Object(data: data, contentType: "video/mp4"))
    }

    @Test func dataUploadIsOneSignedPut() async throws {
        let fixture = try Fixture()
        try await fixture.client.upload(data: Data("<html>".utf8), key: "toma/x/index.html", contentType: "text/html; charset=utf-8")
        let put = try #require(fixture.fake.requests.first)
        #expect(fixture.fake.requests.count == 1 && put.method == "PUT" && put.signatureMatches)
        #expect(
            fixture.fake.object(at: "/bucket/toma/x/index.html")
                == FakeS3.Object(data: Data("<html>".utf8), contentType: "text/html; charset=utf-8"))
    }

    @Test func signatureSurvivesURLSession() async throws {
        let fixture = try Fixture()
        let key = "toma/ab cd/ñ+1 (2)*=&.mp4"
        try await fixture.client.upload(data: Data("x".utf8), key: key, contentType: "video/mp4")
        let put = try #require(fixture.fake.requests.first)
        // What arrived is what was signed: every segment encoded once, as SigV4 encodes it, and nothing re-encoded.
        #expect(put.path == "/bucket/" + SigV4.uriEncode(key, encodeSlash: false))
        #expect(put.path == "/bucket/toma/ab%20cd/%C3%B1%2B1%20%282%29%2A%3D%26.mp4")
        #expect(put.signatureMatches)
        #expect(fixture.fake.object(at: "/bucket/" + key)?.data == Data("x".utf8))
    }

    @Test func largeFileIsMultipart() async throws {
        let fixture = try Fixture()
        let data = Self.bytes(700 << 10)
        try await withTemporaryDirectory { directory in
            let file = try Self.write(data, in: directory)
            let sent = try await fixture.client.upload(file: file, key: "toma/x/video.mp4", contentType: "video/mp4", progress: nil)
            #expect(sent == Int64(data.count))
        }
        let requests = fixture.fake.requests
        #expect(requests.map(\.method) == ["POST", "PUT", "PUT", "PUT", "POST"])
        #expect(requests.allSatisfy { $0.signatureMatches })
        #expect(requests[0].queryItems == ["uploads": ""])
        #expect(requests[0].headers["content-type"] == "video/mp4")
        let uploadID = try #require(requests[1].queryItems["uploadId"])
        #expect(uploadID.contains("+") && uploadID.contains("/"))
        #expect(requests[1...3].map(\.partNumber) == [1, 2, 3])
        #expect(requests[1...3].map(\.body.count) == [256 << 10, 256 << 10, 188 << 10])
        #expect(requests[1...3].allSatisfy { $0.queryItems["uploadId"] == uploadID })
        #expect(requests[1...3].allSatisfy { $0.headers["x-amz-content-sha256"] == Self.sha256($0.body) })
        #expect(requests[4].queryItems == ["uploadId": uploadID])
        let complete = String(decoding: requests[4].body, as: UTF8.self)
        let etags = requests[1...3].map { FakeS3.etag($0.body) }
        for (index, etag) in etags.enumerated() {
            #expect(complete.contains("<Part><PartNumber>\(index + 1)</PartNumber><ETag>\(etag)</ETag></Part>"))
        }
        #expect(fixture.fake.object(at: "/bucket/toma/x/video.mp4") == FakeS3.Object(data: data, contentType: "video/mp4"))
        #expect(fixture.fake.openUploads == 0)
    }

    @Test func completeWithAnErrorBodyFails() async throws {
        let fixture = try Fixture()
        fixture.fake.script(
            when: { request, _ in request.method == "POST" && request.queryItems["uploadId"] != nil },
            .status(200, body: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\n  <Error><Code>InvalidPart</Code><Message>m</Message></Error>"))
        let error = await Self.shareError {
            try await withTemporaryDirectory { directory in
                let file = try Self.write(Self.bytes(600 << 10), in: directory)
                _ = try await fixture.client.upload(file: file, key: "toma/x/video.mp4", contentType: "video/mp4", progress: nil)
            }
        }
        #expect(error == .server(status: 200, code: "InvalidPart"))
        // The upload is aborted, and then the key deleted: once `Complete` went out, the object may exist.
        let cleanup = fixture.fake.requests.suffix(2)
        #expect(cleanup.map(\.method) == ["DELETE", "DELETE"])
        #expect(cleanup.first?.queryItems["uploadId"] != nil && cleanup.last?.query == nil)
        #expect(cleanup.last?.path == "/bucket/toma/x/video.mp4")
        #expect(cleanup.allSatisfy { $0.signatureMatches })
        #expect(fixture.fake.openUploads == 0)
        #expect(fixture.fake.object(at: "/bucket/toma/x/video.mp4") == nil)
    }

    /// Review I1: `Complete` made the object, its answer was lost, and the retry is told `NoSuchUpload`.
    @Test func lostCompleteAnswerRemovesTheObject() async throws {
        let fixture = try Fixture()
        fixture.fake.script(
            when: { request, _ in request.method == "POST" && request.queryItems["uploadId"] != nil },
            .processThenFail(.networkConnectionLost))
        let error = await Self.shareError {
            try await withTemporaryDirectory { directory in
                let file = try Self.write(Self.bytes(600 << 10), in: directory)
                _ = try await fixture.client.upload(file: file, key: "toma/x/video.mp4", contentType: "video/mp4", progress: nil)
            }
        }
        #expect(error == .server(status: 404, code: "NoSuchUpload"))
        let completes = fixture.fake.requests.filter { $0.method == "POST" && $0.queryItems["uploadId"] != nil }
        #expect(completes.count == 2)
        let last = try #require(fixture.fake.requests.last)
        #expect(last.method == "DELETE" && last.query == nil && last.path == "/bucket/toma/x/video.mp4")
        #expect(fixture.fake.object(at: "/bucket/toma/x/video.mp4") == nil)
        #expect(fixture.fake.openUploads == 0)
    }

    /// Review I1: the person cancels while `Complete` runs, and the storage finishes it anyway.
    @Test func cancelDuringCompleteRemovesTheObject() async throws {
        let fixture = try Fixture()
        fixture.fake.script(
            when: { request, _ in request.method == "POST" && request.queryItems["uploadId"] != nil }, .processThenHang)
        try await withTemporaryDirectory { directory in
            let file = try Self.write(Self.bytes(600 << 10), in: directory)
            let client = fixture.client
            let upload = Task {
                try await client.upload(file: file, key: "toma/x/video.mp4", contentType: "video/mp4", progress: nil)
            }
            let completing = await eventually { fixture.fake.object(at: "/bucket/toma/x/video.mp4") != nil }
            #expect(completing)
            upload.cancel()
            let error = await Self.shareError { _ = try await upload.value }
            #expect(error == .cancelled)
        }
        let last = try #require(fixture.fake.requests.last)
        #expect(last.method == "DELETE" && last.query == nil && last.signatureMatches)
        #expect(fixture.fake.object(at: "/bucket/toma/x/video.mp4") == nil)
        #expect(fixture.fake.openUploads == 0)
    }

    /// Review I1: every attempt of a PUT reached the storage, and every answer was lost.
    @Test func lostPutAnswersRemoveTheObject() async throws {
        let fixture = try Fixture()
        fixture.fake.script(
            when: { request, _ in request.method == "PUT" }, .processThenFail(.timedOut), .processThenFail(.timedOut),
            .processThenFail(.timedOut), .processThenFail(.timedOut))
        let error = await Self.shareError {
            try await fixture.client.upload(data: Data("<html>".utf8), key: "toma/x/index.html", contentType: "text/html")
        }
        #expect(error == .network(.timedOut))
        #expect(fixture.fake.requests.map(\.method) == ["PUT", "PUT", "PUT", "PUT", "DELETE"])
        #expect(fixture.fake.object(at: "/bucket/toma/x/index.html") == nil)

        // A PUT the storage refused with an answer left nothing: no delete follows.
        let refused = try Fixture()
        refused.fake.script(request: 1, .error(403, code: "AccessDenied"))
        _ = await Self.shareError {
            try await refused.client.upload(data: Data("x".utf8), key: "toma/x/index.html", contentType: "text/html")
        }
        #expect(refused.fake.requests.map(\.method) == ["PUT"])
    }

    /// Review M1: `CreateMultipartUpload` is not idempotent, so a lost answer is not followed by a second one.
    @Test func createIsNeverSentTwice() async throws {
        let fixture = try Fixture()
        fixture.fake.script(request: 1, .processThenFail(.networkConnectionLost))
        let error = await Self.shareError {
            try await withTemporaryDirectory { directory in
                let file = try Self.write(Self.bytes(600 << 10), in: directory)
                _ = try await fixture.client.upload(file: file, key: "toma/x/video.mp4", contentType: "video/mp4", progress: nil)
            }
        }
        #expect(error == .network(.networkConnectionLost))
        #expect(fixture.fake.requests.count == 1 && fixture.pauses.all.isEmpty)
        // An answered failure is still retried: the storage said it made nothing.
        let answered = try Fixture()
        answered.fake.script(request: 1, .error(503, code: "SlowDown"))
        try await withTemporaryDirectory { directory in
            let file = try Self.write(Self.bytes(600 << 10), in: directory)
            _ = try await answered.client.upload(file: file, key: "toma/x/video.mp4", contentType: "video/mp4", progress: nil)
        }
        #expect(answered.fake.openUploads == 0 && answered.fake.object(at: "/bucket/toma/x/video.mp4") != nil)
    }

    /// Review M2: a cleanup on a stuck network gives up at `cleanupTime`, so cancelling or quitting never waits on it.
    @Test func stuckCleanupGivesUpAtItsDeadline() async throws {
        let limits = S3Client.Limits(singlePut: 512 << 10, partSize: 256 << 10, cleanupTime: .milliseconds(300))
        let fixture = try Fixture(limits: limits)
        fixture.fake.script(when: { request, _ in request.partNumber == 2 }, .error(403, code: "AccessDenied"))
        fixture.fake.script(when: { request, _ in request.method == "DELETE" }, .hang)
        let started = ContinuousClock.now
        let error = await Self.shareError {
            try await withTemporaryDirectory { directory in
                let file = try Self.write(Self.bytes(700 << 10), in: directory)
                _ = try await fixture.client.upload(file: file, key: "toma/x/video.mp4", contentType: "video/mp4", progress: nil)
            }
        }
        #expect(error == .authentication(code: "AccessDenied"))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(fixture.fake.requests.last?.method == "DELETE")
    }

    @Test func failedPartAbortsTheUpload() async throws {
        let fixture = try Fixture()
        fixture.fake.script(when: { request, _ in request.partNumber == 2 }, .error(403, code: "AccessDenied"))
        let error = await Self.shareError {
            try await withTemporaryDirectory { directory in
                let file = try Self.write(Self.bytes(700 << 10), in: directory)
                _ = try await fixture.client.upload(file: file, key: "toma/x/video.mp4", contentType: "video/mp4", progress: nil)
            }
        }
        #expect(error == .authentication(code: "AccessDenied"))
        let requests = fixture.fake.requests
        #expect(requests.map(\.method) == ["POST", "PUT", "PUT", "DELETE"])
        #expect(requests.last?.queryItems["uploadId"] == requests[1].queryItems["uploadId"])
        #expect(!requests.contains { $0.method == "POST" && $0.queryItems["uploadId"] != nil })
        #expect(fixture.fake.openUploads == 0)
        #expect(fixture.pauses.all.isEmpty)
    }

    @Test func transientErrorsAreRetriedWithANewSignature() async throws {
        let fixture = try Fixture()
        fixture.fake.script(request: 1, .error(503, code: "SlowDown"))
        fixture.fake.script(request: 2, .error(503, code: "SlowDown"))
        try await fixture.client.upload(data: Data("poster".utf8), key: "toma/x/poster.jpg", contentType: "image/jpeg")
        let requests = fixture.fake.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.signatureMatches })
        let dates = requests.compactMap { $0.headers["x-amz-date"] }
        #expect(Set(dates).count == 3)
        #expect(Set(requests.compactMap { $0.headers["authorization"] }).count == 3)
        #expect(fixture.pauses.all == [.seconds(1), .seconds(2)])
        #expect(fixture.fake.object(at: "/bucket/toma/x/poster.jpg")?.data == Data("poster".utf8))
    }

    @Test func networkErrorsAndCodesInA400AreRetried() async throws {
        let fixture = try Fixture()
        fixture.fake.script(request: 1, .networkFailure(.networkConnectionLost))
        fixture.fake.script(request: 2, .error(400, code: "RequestTimeout"))
        fixture.fake.script(request: 3, .error(429, code: "TooManyRequests"))
        try await fixture.client.upload(data: Data("p".utf8), key: "toma/x/poster.jpg", contentType: "image/jpeg")
        #expect(fixture.fake.requests.count == 4)
        #expect(fixture.pauses.all == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test func fourFailuresGiveUp() async throws {
        let fixture = try Fixture()
        fixture.fake.script(
            when: { _, _ in true }, .error(500, code: "InternalError"), .error(500, code: "InternalError"),
            .error(500, code: "InternalError"), .error(500, code: "InternalError"))
        let error = await Self.shareError {
            try await fixture.client.upload(data: Data("p".utf8), key: "toma/x/poster.jpg", contentType: "image/jpeg")
        }
        #expect(error == .server(status: 500, code: "InternalError"))
        #expect(fixture.fake.requests.count == S3Client.maximumAttempts)
        #expect(fixture.pauses.all == [.seconds(1), .seconds(2), .seconds(4)])

        let lost = try Fixture()
        lost.fake.script(
            when: { _, _ in true }, .networkFailure(.timedOut), .networkFailure(.timedOut), .networkFailure(.timedOut),
            .networkFailure(.timedOut))
        let networkError = await Self.shareError {
            try await lost.client.upload(data: Data("p".utf8), key: "toma/x/poster.jpg", contentType: "image/jpeg")
        }
        #expect(networkError == .network(.timedOut))
        // No answer ever came, so the PUT may have arrived: the key is deleted after it.
        #expect(lost.fake.requests.map(\.method) == ["PUT", "PUT", "PUT", "PUT", "DELETE"])
    }

    @Test func otherClientErrorsAreNotRetried() async throws {
        let signature = try Fixture()
        signature.fake.script(request: 1, .error(403, code: "SignatureDoesNotMatch"))
        let first = await Self.shareError {
            try await signature.client.upload(data: Data("p".utf8), key: "toma/x/a", contentType: "text/plain")
        }
        #expect(first == .authentication(code: "SignatureDoesNotMatch"))
        #expect(signature.fake.requests.count == 1 && signature.pauses.all.isEmpty)

        let bucket = try Fixture()
        bucket.fake.script(request: 1, .error(404, code: "NoSuchBucket"))
        let second = await Self.shareError {
            try await bucket.client.upload(data: Data("p".utf8), key: "toma/x/a", contentType: "text/plain")
        }
        #expect(second == .noSuchBucket)
        #expect(bucket.fake.requests.count == 1)

        let invalid = try Fixture()
        invalid.fake.script(request: 1, .error(400, code: "EntityTooLarge"))
        let third = await Self.shareError {
            try await invalid.client.upload(data: Data("p".utf8), key: "toma/x/a", contentType: "text/plain")
        }
        #expect(third == .server(status: 400, code: "EntityTooLarge"))
        #expect(invalid.fake.requests.count == 1)
    }

    @Test func clockSkewIsCorrectedOnce() async throws {
        let fixture = try Fixture()
        let serverTime = fixture.clock.current.addingTimeInterval(20 * 60)
        fixture.fake.setServerTime(serverTime)
        try await fixture.client.upload(data: Data("p".utf8), key: "toma/x/poster.jpg", contentType: "image/jpeg")
        let requests = fixture.fake.requests
        #expect(requests.count == 2)
        let retried = try #require(requests.last?.headers["x-amz-date"].flatMap(FakeS3.parseAmzDate))
        #expect(abs(retried.timeIntervalSince(serverTime)) < 60)
        #expect(fixture.pauses.all.isEmpty)
        // The correction stays for what follows: the next request is right the first time.
        try await fixture.client.delete(key: "toma/x/poster.jpg")
        #expect(fixture.fake.requests.count == 3)
        // A presigned link is signed with the server's time too.
        let link = fixture.client.presignedGET(key: "toma/x/poster.jpg")
        let signedAt = try #require(FakeS3.decodedQuery(link.query(percentEncoded: true))["X-Amz-Date"].flatMap(FakeS3.parseAmzDate))
        #expect(abs(signedAt.timeIntervalSince(serverTime)) < 60)

        let twice = try Fixture()
        let date = twice.clock.current.addingTimeInterval(20 * 60)
        twice.fake.script(request: 1, .error(403, code: "RequestTimeTooSkewed", date: date))
        twice.fake.script(request: 2, .error(403, code: "RequestTimeTooSkewed", date: date))
        let error = await Self.shareError {
            try await twice.client.upload(data: Data("p".utf8), key: "toma/x/poster.jpg", contentType: "image/jpeg")
        }
        #expect(error == .clockSkew)
        #expect(twice.fake.requests.count == 2)
    }

    @Test func cancellingAbortsTheMultipart() async throws {
        let fixture = try Fixture()
        fixture.fake.script(when: { request, _ in request.partNumber == 2 }, .hang)
        try await withTemporaryDirectory { directory in
            let file = try Self.write(Self.bytes(700 << 10), in: directory)
            let client = fixture.client
            let upload = Task {
                try await client.upload(file: file, key: "toma/x/video.mp4", contentType: "video/mp4", progress: nil)
            }
            let reachedPartTwo = await eventually { fixture.fake.requests.contains { $0.partNumber == 2 } }
            #expect(reachedPartTwo)
            upload.cancel()
            let error = await Self.shareError { _ = try await upload.value }
            #expect(error == .cancelled)
        }
        let requests = fixture.fake.requests
        let abort = try #require(requests.last)
        #expect(abort.method == "DELETE" && abort.queryItems["uploadId"] == requests[0...].first { $0.partNumber == 1 }?.queryItems["uploadId"])
        #expect(abort.signatureMatches)
        #expect(!requests.contains { $0.partNumber == 3 })
        #expect(fixture.fake.openUploads == 0)
    }

    @Test func cancelledBeforeStartingSendsNothing() async throws {
        let fixture = try Fixture()
        let client = fixture.client
        let upload = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.upload(data: Data("p".utf8), key: "toma/x/a", contentType: "text/plain")
        }
        let error = await Self.shareError { try await upload.value }
        #expect(error == .cancelled)
        #expect(fixture.fake.requests.isEmpty)
    }

    @Test func deleteAcceptsMissing() async throws {
        let fixture = try Fixture()
        fixture.fake.put(Data("x".utf8), at: "/bucket/toma/x/video.mp4")
        try await fixture.client.delete(key: "toma/x/video.mp4")
        #expect(fixture.fake.object(at: "/bucket/toma/x/video.mp4") == nil)
        #expect(fixture.fake.requests.last?.method == "DELETE" && fixture.fake.requests.last?.signatureMatches == true)
        fixture.fake.script(request: 2, .status(200))
        try await fixture.client.delete(key: "toma/x/video.mp4")
        fixture.fake.script(request: 3, .error(404, code: "NoSuchKey"))
        try await fixture.client.delete(key: "toma/x/video.mp4")
        fixture.fake.script(request: 4, .error(403, code: "AccessDenied"))
        let error = await Self.shareError { try await fixture.client.delete(key: "toma/x/video.mp4") }
        #expect(error == .authentication(code: "AccessDenied"))
        // A missing bucket is another storage, not a deleted object (review M7).
        fixture.fake.script(request: 5, .error(404, code: "NoSuchBucket"))
        let bucket = await Self.shareError { try await fixture.client.delete(key: "toma/x/video.mp4") }
        #expect(bucket == .noSuchBucket)
        #expect(fixture.fake.requests.count == 5)
    }

    /// Review M10: a 501 or a 505 is the same on every attempt.
    @Test func notImplementedIsNotRetried() async throws {
        for status in [501, 505] {
            let fixture = try Fixture()
            fixture.fake.script(request: 1, .error(status, code: "NotImplemented"))
            let error = await Self.shareError {
                try await fixture.client.upload(data: Data("p".utf8), key: "toma/x/a", contentType: "text/plain")
            }
            #expect(error == .server(status: status, code: "NotImplemented"))
            #expect(fixture.fake.requests.count == 1)
        }
    }

    /// Review M8: a link to the file uploads the file it points to, measured as that file.
    @Test func aLinkedFileIsMeasuredAtItsTarget() async throws {
        let fixture = try Fixture()
        let data = Self.bytes(700 << 10)
        try await withTemporaryDirectory { directory in
            let file = try Self.write(data, in: directory)
            let link = directory.appendingPathComponent("link.mp4")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            let sent = try await fixture.client.upload(file: link, key: "toma/x/video.mp4", contentType: "video/mp4", progress: nil)
            #expect(sent == Int64(data.count))
        }
        #expect(fixture.fake.requests.first?.queryItems["uploads"] != nil)
        #expect(fixture.fake.object(at: "/bucket/toma/x/video.mp4")?.data == data)
    }

    @Test func progressRisesToTheFileSize() async throws {
        for size in [700 << 10, 100 << 10] {
            let fixture = try Fixture()
            let log = ProgressLog()
            try await withTemporaryDirectory { directory in
                let file = try Self.write(Self.bytes(size), in: directory)
                _ = try await fixture.client.upload(
                    file: file, key: "toma/x/video.mp4", contentType: "video/mp4", progress: log.record)
            }
            let values = log.all
            #expect(!values.isEmpty)
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "\(values)")
            #expect(values.last == Int64(size))
            if size > Self.limits.singlePut { #expect(values.contains(256 << 10) && values.contains(512 << 10)) }
        }
    }

    @Test func noRequestCarriesTheSecret() async throws {
        let fixture = try Fixture()
        fixture.fake.script(request: 3, .error(503, code: "SlowDown"))
        try await withTemporaryDirectory { directory in
            let file = try Self.write(Self.bytes(700 << 10), in: directory)
            _ = try await fixture.client.upload(file: file, key: "toma/x/video.mp4", contentType: "video/mp4", progress: nil)
        }
        try await fixture.client.upload(data: Data("<html>".utf8), key: "toma/x/index.html", contentType: "text/html")
        try await fixture.client.delete(key: "toma/x/index.html")
        let link = fixture.client.presignedGET(key: "toma/x/index.html")
        let secret = FakeS3.secret
        let encodedSecret = SigV4.uriEncode(secret, encodeSlash: true)
        var texts = [link.absoluteString]
        for request in fixture.fake.requests {
            texts.append(request.url.absoluteString)
            texts.append(contentsOf: request.headers.keys)
            texts.append(contentsOf: request.headers.values)
            texts.append(String(decoding: request.body, as: UTF8.self))
        }
        #expect(fixture.fake.requests.count >= 8)
        for text in texts { #expect(!text.contains(secret) && !text.contains(encodedSecret) && !text.contains("bPxRfiCY")) }
        // The signing key's first step is `AWS4` + the secret; not even that goes out.
        #expect(!texts.contains { $0.contains("AWS4wJal") })
    }

    // MARK: - Links and the session

    @Test func presignedGETLastsTheLinkLifetime() async throws {
        let fixture = try Fixture(linkDays: 3)
        try await fixture.client.upload(data: Data("<html>".utf8), key: "toma/x/index.html", contentType: "text/html")
        let link = fixture.client.presignedGET(key: "toma/x/index.html")
        let items = FakeS3.decodedQuery(link.query(percentEncoded: true))
        #expect(items["X-Amz-Expires"] == "259200" && items["X-Amz-SignedHeaders"] == "host")
        #expect(link.path(percentEncoded: true) == "/bucket/toma/x/index.html")
        // The fake checks the presigned signature like S3: the link opens the page, without any header.
        let (data, response) = try await fixture.fake.session.data(from: link)
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && data == Data("<html>".utf8))
    }

    @Test func publicGETIsUnsigned() async throws {
        let storage = FakeS3()
        let domain = FakeS3(isPublic: true)
        domain.put(Data("Toma".utf8), at: "/toma/.toma-connection-test-x.txt")
        let client = S3Client(
            configuration: try storage.configuration(publicBaseURL: "https://\(domain.host)"), session: storage.session,
            limits: Self.limits)
        let url = try #require(client.configuration.publicURL(key: "toma/.toma-connection-test-x.txt"))
        let (status, body) = try await client.get(publicURL: url)
        #expect(status == 200 && body == Data("Toma".utf8))
        let missing = try await client.get(publicURL: try #require(client.configuration.publicURL(key: "toma/none.txt")))
        #expect(missing.status == 404)
        #expect(domain.requests.allSatisfy { $0.headers["authorization"] == nil && $0.headers["x-amz-date"] == nil })
    }

    @Test func ephemeralSessionKeepsNothing() {
        let configuration = S3Client.ephemeralSession().configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 60)
        #expect(configuration.timeoutIntervalForResource == 24 * 60 * 60)
    }
}
