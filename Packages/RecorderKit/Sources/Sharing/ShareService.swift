// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Analysis
import Foundation
import ImageIO
import Synchronization
import os

/// Uploads a link's three objects and gives the link (design §8.1–§8.2; plan 5a decisions 7, 8 and 12): `video.mp4`,
/// `poster.jpg` and, last, `index.html` (`sharePage-1`), to `<prefix><id>/`. With a public base URL the link is
/// `<base>/<prefix><id>/index.html` and never expires; without one it is `index.html`'s presigned URL, and the page
/// carries the video's and the poster's own presigned URLs, all three signed at the same instant for the same time, so
/// they expire together. Whatever fails or is cancelled removes what was uploaded of that link before this throws.
///
/// It only connects when called: the app and `toma` call it on the person's gesture ("Share", "Test Connection",
/// "Delete from Storage", `toma share`, the `share` tool). The secret is only ever given to the signer: it is never in a
/// record, the page, a URL, an error or a log.
public struct ShareService: Sendable {
    public static let videoType = "video/mp4"
    public static let posterType = "image/jpeg"
    public static let pageType = "text/html; charset=utf-8"

    private let session: URLSession
    private let labels: SharePage.Labels
    private let limits: S3Client.Limits
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    private let pause: @Sendable (Duration) async throws -> Void

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Share")

    /// `session` is `S3Client.ephemeralSession()` in the app and `toma`, a fake's in a test; `labels` are the page's
    /// words; `now`, `makeID` and `pause` are a test's own clock, ids and waits.
    public init(
        session: URLSession, labels: SharePage.Labels = .english, limits: S3Client.Limits = .standard,
        now: @escaping @Sendable () -> Date = Date.init, makeID: @escaping @Sendable () -> String = ShareID.random,
        pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.session = session
        self.labels = labels
        self.limits = limits
        self.now = now
        self.makeID = makeID
        self.pause = pause
    }

    // MARK: - Share

    /// Uploads `video` and `poster` (a JPEG, whose size is the page's) and then the page of `title`, `summary` and
    /// `chapters`, and gives the link's record, with `documentHash` empty (the share job fills it in). `progress` gets the
    /// fraction of the bytes of the three objects uploaded, rising, and 1 last.
    /// - Throws: a `ShareError` (`.notConfigured` before connecting; `.cancelled` when the task is cancelled), or the
    ///   error of reading `video` or `poster`. Before it throws, what was uploaded of this link is removed.
    public func share(
        video: URL, poster: URL, title: String, summary: String?, chapters: [Chapter],
        preferences: SharePreferences, secret: String,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> ShareRecord {
        let configuration = try Self.configuration(preferences, secret: secret)
        let clock = LinkClock(now)
        let client = S3Client(
            configuration: configuration, session: session, limits: limits, now: { clock.now() }, pause: pause)
        let id = makeID()
        let folder = configuration.prefix + id + "/"
        let keys = ShareRecord.objectNames.map { folder + $0 }
        let (videoKey, posterKey, pageKey) = (keys[0], keys[1], keys[2])

        let size = try Self.pixelSize(ofJPEG: poster)
        let videoBytes = try Self.fileSize(video), posterBytes = try Self.fileSize(poster)
        let duration = await Self.duration(of: video) ?? chapters.last.map { $0.start + 1 } ?? 0
        func page(_ links: Links) -> Data {
            Data(SharePage.html(
                SharePage.Content(
                    title: title, summary: summary, chapters: chapters, videoURL: links.video, posterURL: links.poster,
                    pageURL: links.isPublic ? links.page : nil, width: size.width, height: size.height,
                    duration: duration),
                labels: labels).utf8)
        }
        // The page's URLs have the same length whenever they are signed: its size now is its size later.
        let estimate = Int64(page(Self.links(videoKey, posterKey, pageKey, client: client)).count)
        let meter = FractionMeter(total: videoBytes + posterBytes + estimate, progress)

        var started: [String] = []
        do {
            started.append(videoKey)
            let sentVideo = try await client.upload(
                file: video, key: videoKey, contentType: Self.videoType, progress: { meter.report($0) })
            started.append(posterKey)
            let sentPoster = try await client.upload(
                file: poster, key: posterKey, contentType: Self.posterType, progress: { meter.report(sentVideo + $0) })
            // Signed now, after the uploads, so a clock the storage corrected is the one the links are signed with; all
            // three at the same instant.
            let instant = now()
            let links = clock.held(at: instant) { Self.links(videoKey, posterKey, pageKey, client: client) }
            let html = page(links)
            started.append(pageKey)
            try await client.upload(data: html, key: pageKey, contentType: Self.pageType)
            meter.finish()
            return ShareRecord(
                id: id, url: links.page.absoluteString, createdAt: instant,
                expiresAt: links.isPublic ? nil : instant.addingTimeInterval(TimeInterval(configuration.linkLifetime)),
                bytes: sentVideo + sentPoster + Int64(html.count), documentHash: "",
                endpoint: configuration.endpoint.absoluteString, bucket: configuration.bucket, folder: folder)
        } catch {
            Self.logger.error("Share of \(folder, privacy: .public) failed; removing what was uploaded")
            _ = await Self.remove(started.reversed(), with: client)
            throw Self.cancelledOr(error)
        }
    }

    // MARK: - Delete

    /// Removes `record`'s three objects, the page first, so the link stops working at once. A record of another endpoint
    /// or bucket than `preferences` is `.otherStorage`, without connecting; an object already gone is not an error.
    public func delete(_ record: ShareRecord, preferences: SharePreferences, secret: String) async throws {
        let configuration = try Self.configuration(preferences, secret: secret)
        // The record's endpoint and bucket, read as the settings would be, so `HTTPS://Host/` is `https://host`.
        var recorded = preferences
        recorded.endpoint = record.endpoint
        recorded.bucket = record.bucket
        guard let storage = try? ShareConfiguration(preferences: recorded, secret: secret),
            storage.endpoint == configuration.endpoint, storage.bucket == configuration.bucket
        else { throw ShareError.otherStorage }
        let client = S3Client(configuration: configuration, session: session, limits: limits, now: now, pause: pause)
        do {
            for key in record.objectKeys.reversed() {
                try await client.delete(key: key)
            }
        } catch {
            throw Self.cancelledOr(error)
        }
    }

    // MARK: - Test Connection

    /// "Test Connection" (decision 12): uploads `<prefix>.toma-connection-test-<id>.txt` ("Toma", `text/plain`); with a
    /// public base URL, an unsigned GET of its public URL must give 200 and "Toma" (else `.publicURLNotServing`); and it
    /// deletes it always, the GET failed or not.
    public func testConnection(preferences: SharePreferences, secret: String) async throws {
        let configuration = try Self.configuration(preferences, secret: secret)
        let client = S3Client(configuration: configuration, session: session, limits: limits, now: now, pause: pause)
        let key = configuration.prefix + ".toma-connection-test-\(makeID()).txt"
        let body = Data("Toma".utf8)
        var failure: (any Error)?
        do {
            try await client.upload(data: body, key: key, contentType: "text/plain")
            if let publicURL = configuration.publicURL(key: key) {
                let (status, data) = try await client.get(publicURL: publicURL)
                if status != 200 || data != body { failure = ShareError.publicURLNotServing(status: status) }
            }
        } catch {
            // A PUT whose answer was lost may still have stored it: it is deleted all the same.
            failure = error
        }
        let removal = await Self.remove([key], with: client)
        if let failure { throw Self.cancelledOr(failure) }
        if let removal { throw Self.cancelledOr(removal) }
    }

    // MARK: - Private

    private struct Links {
        var video: URL
        var poster: URL
        var page: URL
        /// Public URLs (no expiry), or presigned ones.
        var isPublic: Bool
    }

    /// The URLs of a link's objects: their public URLs, or their presigned GETs at the client's clock now.
    private static func links(_ video: String, _ poster: String, _ page: String, client: S3Client) -> Links {
        let configuration = client.configuration
        if let videoURL = configuration.publicURL(key: video), let posterURL = configuration.publicURL(key: poster),
            let pageURL = configuration.publicURL(key: page)
        {
            return Links(video: videoURL, poster: posterURL, page: pageURL, isPublic: true)
        }
        return Links(
            video: client.presignedGET(key: video), poster: client.presignedGET(key: poster),
            page: client.presignedGET(key: page), isPublic: false)
    }

    static func configuration(_ preferences: SharePreferences, secret: String) throws(ShareError) -> ShareConfiguration {
        do {
            return try ShareConfiguration(preferences: preferences, secret: secret)
        } catch {
            throw .notConfigured(error)
        }
    }

    /// Deletes `keys` in order, in a task of its own that a cancellation does not reach, trying every one; the first
    /// error, if any. What cannot be deleted stays to the storage's lifecycle rules (the client logged its key).
    static func remove(_ keys: [String], with client: S3Client) async -> (any Error)? {
        await Task {
            var first: (any Error)?
            for key in keys {
                do {
                    try await client.delete(key: key)
                } catch {
                    first = first ?? error
                }
            }
            return first
        }.value
    }

    /// `.cancelled` for a task that was cancelled or an error that is a cancellation, else `error`.
    static func cancelledOr(_ error: any Error) -> any Error {
        Task.isCancelled || S3Client.isCancellation(error) ? ShareError.cancelled : error
    }

    /// A JPEG's size in pixels, upright.
    private static func pixelSize(ofJPEG url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// The video's duration in ns; `nil` if it cannot be read (the page only needs it to write a chapter's hours).
    private static func duration(of video: URL) async -> Int64? {
        guard let time = try? await AVURLAsset(url: video).load(.duration), time.isNumeric, time.seconds > 0 else {
            return nil
        }
        return CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
    }
}

/// The clock a share's client signs with: the Mac's, held at one instant while the three links are presigned, so they
/// carry the same `X-Amz-Date` and expire together.
private final class LinkClock: Sendable {
    private let base: @Sendable () -> Date
    private let instant = Mutex<Date?>(nil)

    init(_ base: @escaping @Sendable () -> Date) { self.base = base }

    func now() -> Date { instant.withLock { $0 } ?? base() }

    func held<T>(at date: Date, _ body: () -> T) -> T {
        instant.withLock { $0 = date }
        defer { instant.withLock { $0 = nil } }
        return body()
    }
}

/// The fraction of `total` bytes sent, only ever rising, at most 1.
private final class FractionMeter: Sendable {
    private let total: Int64
    private let callback: (@Sendable (Double) -> Void)?
    private let reported = Mutex<Double>(-1)

    init(total: Int64, _ callback: (@Sendable (Double) -> Void)?) {
        self.total = max(total, 1)
        self.callback = callback
    }

    func report(_ bytes: Int64) {
        send(min(Double(bytes) / Double(total), 1))
    }

    func finish() { send(1) }

    /// Called under the lock so two reports never arrive out of order.
    private func send(_ fraction: Double) {
        guard let callback else { return }
        reported.withLock { reported in
            guard fraction > reported else { return }
            reported = fraction
            callback(fraction)
        }
    }
}
