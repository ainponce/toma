// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import Foundation
import ImageIO
import ProjectFormat
import RecorderKitTestSupport
@testable import Sharing
import Synchronization
import Testing

// The share service (plan 5a decisions 7, 8 and 12): the three objects of a link, the page last; a public link or three
// presigned URLs that expire together; what fails or is cancelled removes what was uploaded; "Delete from Storage";
// "Test Connection"; and the secret, nowhere but in the signatures.

private let shareID = "k3m7q2x4za"
private let now = Date(timeIntervalSince1970: 1_795_000_000)
private let chapters = [Chapter(start: 0, title: "Intro"), Chapter(start: 65_000_000_000, title: "La demo & más")]

/// A link's files: a video (any bytes: the storage does not look) and a JPEG poster of 320 × 180.
private struct Files {
    let video: URL
    let poster: URL
    var videoData: Data { (try? Data(contentsOf: video)) ?? Data() }
    var posterData: Data { (try? Data(contentsOf: poster)) ?? Data() }

    init(in dir: URL, videoBytes: Int = 300_000) throws {
        video = dir.appending(path: "video.mp4")
        try Data((0..<videoBytes).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: video)
        poster = dir.appending(path: "poster.jpg")
        let context = try #require(CGContext(
            data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.4, green: 0.3, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(poster as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }
}

private func service(
    _ fake: FakeS3, now clock: @escaping @Sendable () -> Date = { now }, ids: [String] = [shareID]
) -> ShareService {
    let next = Mutex(0)
    return ShareService(
        session: fake.session, now: clock,
        makeID: { next.withLock { n in defer { n += 1 }; return ids[min(n, ids.count - 1)] } },
        pause: { _ in })
}

private func share(
    _ service: ShareService, _ files: Files, _ preferences: SharePreferences,
    progress: (@Sendable (Double) -> Void)? = nil
) async throws -> ShareRecord {
    try await service.share(
        video: files.video, poster: files.poster, title: "Demo de Toma", summary: "Un resumen.\nEn dos líneas.",
        chapters: chapters, preferences: preferences, secret: FakeS3.secret, progress: progress)
}

/// The `ShareError` `body` throws (a test issue if it throws another error).
private func shareError(_ body: () async throws -> Void) async -> ShareError? {
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

/// The value of `name="…"` in `html`, unescaped as a browser reads it.
private func attribute(_ name: String, in html: String) throws -> String {
    let match = try #require(html.firstMatch(of: try Regex(" \(name)=\"([^\"]*)\"", as: (Substring, Substring).self)))
    return String(match.output.1).replacingOccurrences(of: "&amp;", with: "&")
}

private func path(_ object: String) -> String { "/bucket/toma/\(shareID)/\(object)" }

@Suite struct ShareServiceTests {
    @Test func publicShareUploadsThreeObjectsPageLast() async throws {
        let fake = FakeS3()
        let fractions = Mutex<[Double]>([])
        try await withTemporaryDirectory { dir in
            let files = try Files(in: dir)
            let record = try await share(
                service(fake), files, fake.preferences(publicBaseURL: "https://cdn.example.com/"),
                progress: { fraction in fractions.withLock { $0.append(fraction) } })

            let requests = fake.requests
            #expect(requests.map(\.method) == ["PUT", "PUT", "PUT"])
            #expect(requests.map(\.objectPath) == [path("video.mp4"), path("poster.jpg"), path("index.html")])
            #expect(requests.map { $0.headers["content-type"] } == ["video/mp4", "image/jpeg", "text/html; charset=utf-8"])
            #expect(requests.allSatisfy { $0.signatureMatches })
            #expect(fake.object(at: path("video.mp4"))?.data == files.videoData)
            #expect(fake.object(at: path("poster.jpg"))?.data == files.posterData)

            let page = try #require(fake.object(at: path("index.html"))).data
            let base = "https://cdn.example.com/toma/\(shareID)/"
            let expected = SharePage.html(
                SharePage.Content(
                    title: "Demo de Toma", summary: "Un resumen.\nEn dos líneas.", chapters: chapters,
                    videoURL: URL(string: base + "video.mp4")!, posterURL: URL(string: base + "poster.jpg")!,
                    pageURL: URL(string: base + "index.html")!, width: 320, height: 180, duration: 0),
                labels: .english)
            #expect(String(decoding: page, as: UTF8.self) == expected)

            #expect(record.id == shareID)
            #expect(record.url == "https://cdn.example.com/toma/k3m7q2x4za/index.html")
            #expect(record.expiresAt == nil && record.isPublic)
            #expect(record.createdAt == now)
            #expect(record.bytes == Int64(files.videoData.count + files.posterData.count + page.count))
            #expect(record.documentHash == "")
            #expect(record.endpoint == "https://\(fake.host)" && record.bucket == "bucket")
            #expect(record.folder == "toma/k3m7q2x4za/")
        }
        let reported = fractions.withLock { $0 }
        #expect(reported.last == 1)
        #expect(zip(reported, reported.dropFirst()).allSatisfy { $0 < $1 })
        #expect(reported.allSatisfy { (0...1).contains($0) })
    }

    @Test func signedShareExpiresTogether() async throws {
        let fake = FakeS3()
        // A clock that moves on every time it is read: the three links are still signed at one instant.
        let reads = Mutex(0)
        let moving: @Sendable () -> Date = { now.addingTimeInterval(0.7 * Double(reads.withLock { $0 += 1; return $0 })) }
        try await withTemporaryDirectory { dir in
            let files = try Files(in: dir)
            let record = try await share(service(fake, now: moving), files, fake.preferences(linkDays: 3))

            let link = try #require(URL(string: record.url))
            #expect(link.host() == fake.host && link.path() == path("index.html"))
            let query = FakeS3.decodedQuery(link.query(percentEncoded: true))
            #expect(query["X-Amz-Expires"] == "259200")
            let signedAt = try #require(query["X-Amz-Date"].flatMap(FakeS3.parseAmzDate))
            #expect(record.createdAt == signedAt)
            #expect(record.expiresAt == signedAt.addingTimeInterval(3 * 86_400))
            #expect(signedAt > now && signedAt < now.addingTimeInterval(60))
            #expect(!record.isPublic)

            let page = try #require(fake.object(at: path("index.html"))).data
            let html = String(decoding: page, as: UTF8.self)
            let video = try #require(URL(string: try attribute("src", in: html)))
            let poster = try #require(URL(string: try attribute("poster", in: html)))
            #expect(video.path() == path("video.mp4") && poster.path() == path("poster.jpg"))
            for url in [video, poster] {
                let items = FakeS3.decodedQuery(url.query(percentEncoded: true))
                #expect(items["X-Amz-Date"] == query["X-Amz-Date"])
                #expect(items["X-Amz-Expires"] == "259200")
            }
            // No public URL: the page has no `og:url`, which would expire.
            #expect(!html.contains("og:url"))

            // Each link opens for whoever has it.
            let session = fake.session
            let (opened, answer) = try await session.data(from: link)
            #expect((answer as? HTTPURLResponse)?.statusCode == 200 && opened == page)
            let (movie, movieAnswer) = try await session.data(from: video)
            #expect((movieAnswer as? HTTPURLResponse)?.statusCode == 200 && movie == files.videoData)
            let (picture, _) = try await session.data(from: poster)
            #expect(picture == files.posterData)
        }
    }

    @Test func failedUploadRemovesWhatWasUploaded() async throws {
        let fake = FakeS3()
        fake.script(
            when: { request, _ in request.method == "PUT" && request.objectPath == path("poster.jpg") },
            .error(403, code: "AccessDenied"))
        try await withTemporaryDirectory { dir in
            let files = try Files(in: dir)
            let error = await shareError { _ = try await share(service(fake), files, fake.preferences()) }
            #expect(error == .authentication(code: "AccessDenied"))
        }
        let requests = fake.requests
        let deleted = requests.filter { $0.method == "DELETE" }.map(\.objectPath)
        #expect(deleted.contains(path("video.mp4")))
        #expect(!requests.contains { $0.objectPath == path("index.html") })
        #expect(fake.object(at: path("video.mp4")) == nil && fake.object(at: path("poster.jpg")) == nil)
    }

    @Test func cancelRemovesWhatWasUploaded() async throws {
        let fake = FakeS3()
        fake.script(when: { request, _ in request.method == "PUT" && request.objectPath == path("poster.jpg") }, .hang)
        try await withTemporaryDirectory { dir in
            let files = try Files(in: dir)
            let shareService = service(fake)
            let preferences = fake.preferences()
            let task = Task { try await share(shareService, files, preferences) }
            let reachedPoster = await eventually(timeout: .seconds(60)) {
                fake.requests.contains { $0.objectPath == path("poster.jpg") }
            }
            #expect(reachedPoster)
            task.cancel()
            let error = await shareError { _ = try await task.value }
            #expect(error == .cancelled)
        }
        let requests = fake.requests
        #expect(requests.contains { $0.method == "DELETE" && $0.objectPath == path("video.mp4") })
        #expect(!requests.contains { $0.objectPath == path("index.html") })
        #expect(fake.object(at: path("video.mp4")) == nil)
    }

    @Test func deleteRemovesTheThreeObjects() async throws {
        let fake = FakeS3()
        try await withTemporaryDirectory { dir in
            let files = try Files(in: dir)
            let shareService = service(fake)
            let record = try await share(shareService, files, fake.preferences())
            let before = fake.requests.count
            try await shareService.delete(record, preferences: fake.preferences(), secret: FakeS3.secret)
            let deletes = fake.requests.dropFirst(before)
            #expect(deletes.map(\.method) == ["DELETE", "DELETE", "DELETE"])
            // The page first: the link stops working at once.
            #expect(deletes.map(\.objectPath) == [path("index.html"), path("poster.jpg"), path("video.mp4")])
            #expect(deletes.allSatisfy { $0.signatureMatches })
            for name in ShareRecord.objectNames { #expect(fake.object(at: path(name)) == nil) }
            // Deleting again is not an error: what is gone is gone.
            try await shareService.delete(record, preferences: fake.preferences(), secret: FakeS3.secret)
        }
    }

    @Test func deleteFromAnotherStorageIsRefused() async throws {
        let fake = FakeS3()
        let record = ShareRecord(
            id: shareID, url: "https://cdn.example.com/toma/\(shareID)/index.html", createdAt: now, expiresAt: nil,
            bytes: 10, documentHash: "", endpoint: "https://\(fake.host)", bucket: "bucket", folder: "toma/\(shareID)/")
        let shareService = service(fake)
        var otherBucket = record
        otherBucket.bucket = "other"
        var otherEndpoint = record
        otherEndpoint.endpoint = "https://elsewhere.example.com"
        for other in [otherBucket, otherEndpoint] {
            let error = await shareError {
                try await shareService.delete(other, preferences: fake.preferences(), secret: FakeS3.secret)
            }
            #expect(error == .otherStorage)
        }
        #expect(fake.requests.isEmpty)
        // The same endpoint written another way is the same storage.
        var sameStorage = record
        sameStorage.endpoint = "HTTPS://\(fake.host.uppercased())/"
        try await shareService.delete(sameStorage, preferences: fake.preferences(), secret: FakeS3.secret)
        #expect(fake.requests.count == 3)
    }

    @Test func testConnectionPutsAndDeletes() async throws {
        let fake = FakeS3()
        try await service(fake).testConnection(preferences: fake.preferences(), secret: FakeS3.secret)
        let requests = fake.requests
        let key = "/bucket/toma/.toma-connection-test-\(shareID).txt"
        #expect(requests.map(\.method) == ["PUT", "DELETE"])
        #expect(requests.allSatisfy { $0.objectPath == key && $0.signatureMatches })
        #expect(requests[0].body == Data("Toma".utf8) && requests[0].headers["content-type"] == "text/plain")
        #expect(fake.object(at: key) == nil)
    }

    @Test func testConnectionChecksThePublicURL() async throws {
        // The bucket served at the fake's own host, as a public domain would: `<host>/bucket/<key>`.
        let fake = FakeS3(isPublic: true)
        let preferences = fake.preferences(publicBaseURL: "https://\(fake.host)/bucket")
        let key = "/bucket/toma/.toma-connection-test-\(shareID).txt"
        try await service(fake).testConnection(preferences: preferences, secret: FakeS3.secret)
        #expect(fake.requests.map(\.method) == ["PUT", "GET", "DELETE"])
        #expect(fake.requests[1].objectPath == key && fake.requests[1].headers["authorization"] == nil)
        #expect(fake.requests[1].query == nil)

        // The public URL does not serve it: the error, and the file is deleted all the same.
        fake.script(when: { request, _ in request.method == "GET" }, .status(403))
        let error = await shareError {
            try await service(fake).testConnection(preferences: preferences, secret: FakeS3.secret)
        }
        #expect(error == .publicURLNotServing(status: 403))
        #expect(fake.requests.dropFirst(3).map(\.method) == ["PUT", "GET", "DELETE"])
        #expect(fake.object(at: key) == nil)

        // A 200 with something else is not serving it either.
        fake.script(when: { request, _ in request.method == "GET" }, .status(200, body: "<html>Not found</html>"))
        let other = await shareError {
            try await service(fake).testConnection(preferences: preferences, secret: FakeS3.secret)
        }
        #expect(other == .publicURLNotServing(status: 200))
        #expect(fake.requests.last?.method == "DELETE")
    }

    @Test func secretNeverInRecordsPageOrErrors() async throws {
        let secret = FakeS3.secret
        let forms = [secret, SigV4.uriEncode(secret, encodeSlash: true), secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!]
        func leaks(_ text: String) -> Bool { forms.contains { text.contains($0) } }
        func leaks(_ data: Data) -> Bool { forms.contains { data.range(of: Data($0.utf8)) != nil } }

        let fake = FakeS3()
        var errors: [ShareError] = []
        var records: [ShareRecord] = []
        try await withTemporaryDirectory { dir in
            let files = try Files(in: dir)
            records.append(try await share(service(fake, ids: ["aaaaaaaaaa"]), files, fake.preferences()))
            records.append(try await share(
                service(fake, ids: ["bbbbbbbbbb"]), files, fake.preferences(publicBaseURL: "https://cdn.example.com")))
            // Failures: refused credentials, a server error, a network error, the public URL, another storage.
            fake.script(when: { request, _ in request.objectPath.hasSuffix("poster.jpg") }, .error(403, code: "SignatureDoesNotMatch"))
            errors += [await shareError { _ = try await share(service(fake, ids: ["cccccccccc"]), files, fake.preferences()) }]
                .compactMap { $0 }
            fake.script(when: { request, _ in request.method == "PUT" }, .error(500, code: "InternalError"), .error(500, code: "InternalError"),
                .error(500, code: "InternalError"), .error(500, code: "InternalError"))
            errors += [await shareError { _ = try await share(service(fake, ids: ["dddddddddd"]), files, fake.preferences()) }]
                .compactMap { $0 }
            fake.script(when: { request, _ in request.method == "PUT" }, .networkFailure(.timedOut), .networkFailure(.timedOut),
                .networkFailure(.timedOut), .networkFailure(.timedOut))
            errors += [await shareError {
                try await service(fake).testConnection(preferences: fake.preferences(), secret: secret)
            }].compactMap { $0 }
            var other = records[0]
            other.bucket = "other"
            errors += [await shareError {
                try await service(fake).delete(other, preferences: fake.preferences(), secret: secret)
            }].compactMap { $0 }
            var broken = fake.preferences()
            broken.bucket = ""
            errors += [await shareError { _ = try await share(service(fake), files, broken) }].compactMap { $0 }
        }
        #expect(errors.count == 5)
        for error in errors {
            #expect(!leaks(String(describing: error)) && !leaks(String(reflecting: error)) && !leaks("\(error)"))
        }
        for record in records {
            #expect(!leaks(try ProjectJSON.encoder().encode(record)))
            #expect(!leaks(String(describing: record)) && !leaks(record.url))
        }
        let requests = fake.requests
        #expect(requests.count > 10)
        for request in requests {
            #expect(!leaks(request.url.absoluteString) && !leaks(request.body))
            #expect(!request.headers.values.contains(where: leaks))
        }
        #expect(!fake.requests.contains { $0.objectPath.hasSuffix("index.html") && leaks($0.body) })
        // What a configuration or a service prints.
        #expect(!leaks(String(describing: try fake.configuration())) && !leaks(String(reflecting: service(fake))))
    }
}
