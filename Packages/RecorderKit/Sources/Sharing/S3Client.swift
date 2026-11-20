// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Synchronization
import os

/// A client for the S3 API, written by hand (design §8.1; plan 5a, decisions 6 and 7): a single PUT up to
/// `Limits.singlePut`, a multipart upload above it, one part at a time; DELETE; an unsigned GET for "Test Connection"; and
/// presigned GET links. Every request is signed again on each attempt. It only ever talks to the configured endpoint
/// (redirects are not followed) and never logs more than the method, the object's key and the HTTP status.
///
/// Everything it throws is a `ShareError`, but for the file to upload when it cannot be read (Foundation's own error).
public struct S3Client: Sendable {
    public struct Limits: Sendable {
        /// Up to this many bytes, one PUT; above, a multipart upload.
        public var singlePut: Int64
        /// The size of each part but the last (S3 allows 10 000 parts; a bigger file gets bigger parts).
        public var partSize: Int

        public static let standard = Limits(singlePut: 64 << 20, partSize: 16 << 20)

        public init(singlePut: Int64, partSize: Int) {
            self.singlePut = singlePut
            self.partSize = partSize
        }
    }

    /// A request is tried this many times at most: three retries, after 1, 2 and 4 s.
    public static let maximumAttempts = 4

    public let configuration: ShareConfiguration
    private let session: URLSession
    private let limits: Limits
    private let clock: ServerClock
    private let pause: @Sendable (Duration) async throws -> Void

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Share")

    /// The session the app and `toma` upload with: ephemeral, nothing cached or kept (no cookies, no credentials), 60 s
    /// without data for a request, a day at most for one.
    public static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// `now` is the Mac's clock (a test's own); `pause` waits between attempts (a test records it instead).
    public init(
        configuration: ShareConfiguration, session: URLSession, limits: Limits = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.configuration = configuration
        self.session = session
        self.limits = limits
        self.clock = ServerClock(now: now)
        self.pause = pause
    }

    // MARK: - Uploads

    /// Uploads the file at `file` as `key`: one PUT, or a multipart upload when it is bigger than `limits.singlePut`. A
    /// multipart upload that fails or is cancelled is aborted before this throws, so no part stays in the bucket.
    /// `progress` gets the bytes sent so far, rising, and the file's size last. Returns the bytes uploaded.
    public func upload(
        file: URL, key: String, contentType: String, progress: (@Sendable (Int64) -> Void)?
    ) async throws -> Int64 {
        let size = try Self.size(of: file)
        let meter = ProgressMeter(progress)
        if size <= limits.singlePut {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            _ = try await send(
                "PUT", key: key, body: data, contentType: contentType, sent: { meter.report($0) })
            meter.report(Int64(data.count))
            return Int64(data.count)
        }
        try await multipart(file: file, size: size, key: key, contentType: contentType, meter: meter)
        return size
    }

    /// Uploads `data` as `key` with one PUT (the poster and the page).
    public func upload(data: Data, key: String, contentType: String) async throws {
        _ = try await send("PUT", key: key, body: data, contentType: contentType)
    }

    /// An unsigned GET of `publicURL` ("Test Connection" checks the public base URL serves what was uploaded). Any status
    /// is returned; only a request without an answer throws.
    public func get(publicURL: URL) async throws -> (status: Int, body: Data) {
        guard !Task.isCancelled else { throw ShareError.cancelled }
        var request = URLRequest(url: publicURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request, delegate: TaskDelegate(sent: nil))
            guard let http = response as? HTTPURLResponse else { throw ShareError.network(.badServerResponse) }
            Self.logger.info("GET public \(publicURL.path(percentEncoded: false), privacy: .public) \(http.statusCode, privacy: .public)")
            return (http.statusCode, data)
        } catch let error as ShareError {
            throw error
        } catch {
            if Task.isCancelled || Self.isCancellation(error) { throw ShareError.cancelled }
            let code = (error as? URLError)?.code ?? .unknown
            Self.logger.error("GET public failed: \(code.rawValue, privacy: .public)")
            throw ShareError.network(code)
        }
    }

    /// Deletes `key`. 200, 204 and 404 are a success: what is gone is gone.
    public func delete(key: String) async throws {
        _ = try await send("DELETE", key: key, acceptsMissing: true)
    }

    /// A presigned GET of `key` that lasts `configuration.linkLifetime`, signed with the server's time when it was
    /// corrected.
    public func presignedGET(key: String) -> URL {
        signer.presignedURL(
            method: "GET", url: configuration.objectURL(key: key), expires: configuration.linkLifetime, date: clock.now())
    }

    // MARK: - Multipart

    private func multipart(file: URL, size: Int64, key: String, contentType: String, meter: ProgressMeter) async throws {
        let partSize = max(Int64(limits.partSize), (size + 9_999) / 10_000)
        let created = try await send("POST", key: key, query: [("uploads", "")], contentType: contentType)
        guard let uploadID = S3XML.uploadID(in: created.body) else {
            throw ShareError.server(status: created.response.statusCode, code: nil)
        }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var parts: [(number: Int, etag: String)] = []
            var offset: Int64 = 0
            while offset < size {
                guard !Task.isCancelled else { throw ShareError.cancelled }
                let count = Int(min(partSize, size - offset))
                try handle.seek(toOffset: UInt64(offset))
                guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: file])
                }
                let number = parts.count + 1
                let base = offset
                let answer = try await send(
                    "PUT", key: key, query: [("partNumber", String(number)), ("uploadId", uploadID)], body: chunk,
                    sent: { meter.report(base + $0) })
                guard let etag = answer.response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
                    throw ShareError.server(status: answer.response.statusCode, code: nil)
                }
                parts.append((number, etag))
                offset += Int64(count)
                meter.report(offset)
            }
            let completed = try await send(
                "POST", key: key, query: [("uploadId", uploadID)], body: S3XML.completeBody(parts: parts),
                contentType: "application/xml", errorsInSuccess: true)
            // A 200 is a success only with its result: anything else may be an upload that never became the object.
            guard S3XML.isCompleteResult(completed.body) else {
                throw ShareError.server(status: completed.response.statusCode, code: nil)
            }
        } catch {
            await abort(key: key, uploadID: uploadID)
            if Self.isCancellation(error) { throw ShareError.cancelled }
            throw error
        }
    }

    /// Aborts the multipart upload, also when the task is cancelled (in a task of its own, which the cancellation does
    /// not reach). A failure is logged: the storage's lifecycle rules are the last resort.
    private func abort(key: String, uploadID: String) async {
        let client = self
        await Task {
            do {
                _ = try await client.send("DELETE", key: key, query: [("uploadId", uploadID)], acceptsMissing: true)
            } catch {
                Self.logger.error("Abort of a multipart upload failed: \(key, privacy: .public)")
            }
        }.value
    }

    // MARK: - One request, with its retries

    private struct Answer {
        let response: HTTPURLResponse
        let body: Data
    }

    /// Sends a signed request to `key` (each attempt signed again with the server-corrected clock) and retries what is
    /// transient (decision 7): a network error, a 5xx, a 429, or `SlowDown`, `InternalError`, `RequestTimeout`; up to
    /// `maximumAttempts` with pauses of 1, 2 and 4 s. `RequestTimeTooSkewed` corrects the clock once from the answer's
    /// `Date`. `errorsInSuccess` reads an `<Error>` in a 2xx as a failure (`CompleteMultipartUpload`).
    private func send(
        _ method: String, key: String, query: [(String, String)] = [], body: Data? = nil, contentType: String? = nil,
        acceptsMissing: Bool = false, errorsInSuccess: Bool = false, sent: (@Sendable (Int64) -> Void)? = nil
    ) async throws(ShareError) -> Answer {
        var request = URLRequest(url: Self.url(configuration.objectURL(key: key), query: query))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let payloadHash = SigV4.hex(SHA256.hash(data: body ?? Data()))
        var attempt = 0
        var correctedClock = false
        while true {
            guard !Task.isCancelled else { throw .cancelled }
            attempt += 1
            let signed = signer.signed(request, payloadHash: payloadHash, date: clock.now())
            let data: Data
            let response: URLResponse
            do {
                let delegate = TaskDelegate(sent: sent)
                if let body {
                    (data, response) = try await session.upload(for: signed, from: body, delegate: delegate)
                } else {
                    (data, response) = try await session.data(for: signed, delegate: delegate)
                }
            } catch {
                if Task.isCancelled || Self.isCancellation(error) {
                    Self.logger.info("\(method, privacy: .public) \(key, privacy: .public) cancelled")
                    throw .cancelled
                }
                let code = (error as? URLError)?.code ?? .unknown
                Self.logger.error("\(method, privacy: .public) \(key, privacy: .public) network \(code.rawValue, privacy: .public)")
                guard Self.retriesNetwork(code), attempt < Self.maximumAttempts else { throw .network(code) }
                try await wait(after: attempt)
                continue
            }
            guard let http = response as? HTTPURLResponse else { throw .network(.badServerResponse) }
            let status = http.statusCode
            Self.logger.info("\(method, privacy: .public) \(key, privacy: .public) \(status, privacy: .public)")
            let success = (200..<300).contains(status)
            let code = success && !errorsInSuccess ? nil : S3XML.errorCode(in: data)
            if success && code == nil { return Answer(response: http, body: data) }
            if status == 404 && acceptsMissing { return Answer(response: http, body: data) }
            if code == "RequestTimeTooSkewed" {
                guard !correctedClock, let serverDate = http.value(forHTTPHeaderField: "Date").flatMap(Self.httpDate) else {
                    throw .clockSkew
                }
                clock.correct(serverDate: serverDate)
                correctedClock = true
                attempt -= 1
                continue
            }
            guard Self.isTransient(status: status, code: code), attempt < Self.maximumAttempts else {
                throw Self.error(status: status, code: code)
            }
            try await wait(after: attempt)
        }
    }

    private func wait(after attempt: Int) async throws(ShareError) {
        do {
            try await pause(.seconds(1 << (attempt - 1)))
        } catch {
            throw .cancelled
        }
    }

    private var signer: SigV4 { SigV4(credentials: configuration.credentials, region: configuration.region) }

    // MARK: - Rules

    /// The object's URL with `query`, each name and value encoded as SigV4 encodes it (a bare `+` would be a space to
    /// S3); a name without a value is written bare (`?uploads`).
    static func url(_ object: URL, query: [(String, String)]) -> URL {
        guard !query.isEmpty, var components = URLComponents(url: object, resolvingAgainstBaseURL: false) else {
            return object
        }
        components.percentEncodedQuery = query.map { name, value in
            let name = SigV4.uriEncode(name, encodeSlash: true)
            return value.isEmpty ? name : "\(name)=\(SigV4.uriEncode(value, encodeSlash: true))"
        }.joined(separator: "&")
        return components.url ?? object
    }

    static let transientCodes: Set<String> = ["SlowDown", "InternalError", "RequestTimeout", "ServiceUnavailable"]

    static func isTransient(status: Int, code: String?) -> Bool {
        status >= 500 || status == 429 || code.map(transientCodes.contains) == true
    }

    static let authenticationCodes: Set<String> = [
        "AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch", "AuthorizationHeaderMalformed", "InvalidToken",
        "ExpiredToken", "AccountProblem", "AllAccessDisabled", "InvalidSecurity", "NotSignedUp", "Unauthorized",
    ]

    static func error(status: Int, code: String?) -> ShareError {
        if code == "NoSuchBucket" { return .noSuchBucket }
        if let code, authenticationCodes.contains(code) { return .authentication(code: code) }
        if status == 401 || status == 403 { return .authentication(code: code ?? String(status)) }
        return .server(status: status, code: code)
    }

    /// Network errors worth another attempt: all but a cancellation and what another attempt cannot change (a bad URL,
    /// the server's certificate, App Transport Security).
    static func retriesNetwork(_ code: URLError.Code) -> Bool {
        let final: Set<URLError.Code> = [
            .cancelled, .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection,
            .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
            .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
            .userAuthenticationRequired, .userCancelledAuthentication, .fileDoesNotExist, .fileIsDirectory,
            .noPermissionsToReadFile, .dataLengthExceedsMaximum,
        ]
        return !final.contains(code)
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? ShareError { return error == .cancelled }
        return (error as? URLError)?.code == .cancelled
    }

    /// An HTTP date (`Fri, 24 May 2013 00:00:00 GMT`), as a server's `Date` header writes it.
    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    private static func size(of file: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// The Mac's clock, moved by the difference with the storage's once a request was refused as `RequestTimeTooSkewed`.
/// Shared by the copies of one client, so the parts after a correction are signed right the first time.
private final class ServerClock: Sendable {
    private let localNow: @Sendable () -> Date
    private let offset = Mutex<TimeInterval>(0)

    init(now: @escaping @Sendable () -> Date) { localNow = now }

    func now() -> Date { localNow().addingTimeInterval(offset.withLock { $0 }) }

    func correct(serverDate: Date) {
        let difference = serverDate.timeIntervalSince(localNow())
        offset.withLock { $0 = difference }
    }
}

/// Reports the bytes sent so far, only ever rising: a retried part starts from zero again, and that is not shown.
private final class ProgressMeter: Sendable {
    private let callback: (@Sendable (Int64) -> Void)?
    private let reported = Mutex<Int64>(-1)

    init(_ callback: (@Sendable (Int64) -> Void)?) { self.callback = callback }

    /// Called under the lock so two reports can never arrive out of order.
    func report(_ bytes: Int64) {
        guard let callback else { return }
        reported.withLock { reported in
            guard bytes > reported else { return }
            reported = bytes
            callback(bytes)
        }
    }
}

/// Each task's delegate: the upload's progress, and no redirect followed (a request only ever goes to the configured
/// endpoint; a 3xx comes back as an error).
private final class TaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let sent: (@Sendable (Int64) -> Void)?

    init(sent: (@Sendable (Int64) -> Void)?) { self.sent = sent }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        sent?(totalBytesSent)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
