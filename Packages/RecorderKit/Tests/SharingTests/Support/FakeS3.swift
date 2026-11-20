// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Sharing
import Synchronization

/// An S3-compatible storage that lives in the test process (plan 5a, Global Constraints): no test ever touches the network.
/// Every request of a session from `FakeS3.session(host:)` lands here, whatever its host; a host no fake owns fails with
/// `cannotFindHost`. Each fake owns one host, so tests that run at once never share a store.
///
/// It keeps every request as it arrived (the path as `URLSession` encoded it, the query, the headers and the body read
/// from `httpBodyStream`), checks the signature again from what arrived, and answers like S3: objects, multipart uploads
/// (`?uploads`, `?partNumber&uploadId`, `?uploadId`, ETags that are the MD5 of the part), deletes and errors. A test can
/// script the answers to some requests (`script(when:_:)`) and give the server its own clock (`serverTime`).
final class FakeS3: Sendable {
    /// One request as the server saw it.
    struct Request: Sendable {
        let method: String
        let url: URL
        /// `url`'s path exactly as it arrived, percent-encoded.
        let path: String
        /// `url`'s query exactly as it arrived, percent-encoded.
        let query: String?
        /// Header names in lower case.
        let headers: [String: String]
        let body: Data
        /// Whether the `Authorization` header matched the signature computed again from what arrived.
        let signatureMatches: Bool

        /// The query's items decoded as S3 decodes them (a bare `+` is a space); a name without a value has "".
        var queryItems: [String: String] { FakeS3.decodedQuery(query) }
        var partNumber: Int? { queryItems["partNumber"].flatMap(Int.init) }
        var isMultipart: Bool { queryItems["uploads"] != nil || queryItems["uploadId"] != nil }
        /// The object's key in the store: the decoded path.
        var objectPath: String { path.removingPercentEncoding ?? path }
    }

    /// A scripted answer.
    enum Reply: Sendable {
        case status(Int, body: String = "", headers: [String: String] = [:])
        /// An S3 `<Error>` document with `code`; `date` becomes the response's `Date` header.
        case error(Int, code: String, date: Date? = nil)
        /// The request fails before any answer, as a lost connection does.
        case networkFailure(URLError.Code)
        /// No answer at all until the task is cancelled.
        case hang
    }

    struct Object: Sendable, Equatable {
        var data: Data
        var contentType: String?
    }

    private struct Upload: Sendable {
        let path: String
        let contentType: String?
        var parts: [Int: Data] = [:]
    }

    private struct Rule: Sendable {
        let matches: @Sendable (Request, Int) -> Bool
        var replies: [Reply]
    }

    private struct State: Sendable {
        var requests: [Request] = []
        var objects: [String: Object] = [:]
        var uploads: [String: Upload] = [:]
        var rules: [Rule] = []
        var uploadCount = 0
        var serverTime: Date?
    }

    /// `host` or `host:port`, in lower case.
    let host: String
    private let credentials: S3Credentials
    private let region: String
    /// Whether a GET without any signature gets the object, as from a bucket's public domain.
    let isPublic: Bool
    private let state = Mutex(State())

    private static let registry = Mutex<[String: FakeS3]>([:])

    /// The credentials every test signs with: AWS's example ones, never real.
    static let accessKeyID = "AKIDEXAMPLE"
    static let secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

    init(
        host: String = "s3-\(UUID().uuidString.prefix(12).lowercased()).test", region: String = "us-east-1",
        isPublic: Bool = false
    ) {
        self.host = host.lowercased()
        self.credentials = S3Credentials(accessKeyID: Self.accessKeyID, secretAccessKey: Self.secret)
        self.region = region
        self.isPublic = isPublic
        Self.registry.withLock { $0[self.host] = self }
    }

    /// A session whose every request lands in a fake, never on the network. `host` must belong to one.
    static func session(host: String) -> URLSession {
        precondition(registry.withLock { $0[host.lowercased()] } != nil, "No fake owns \(host)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeS3Protocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    var session: URLSession { Self.session(host: host) }

    /// The preferences of a storage at this fake: path-style ("other"), bucket `bucket`, prefix `toma/`.
    func preferences(linkDays: Int = 7, publicBaseURL: String = "") -> SharePreferences {
        SharePreferences(
            provider: .other, endpoint: "https://\(host)", region: region, bucket: "bucket", prefix: "toma/",
            accessKeyID: Self.accessKeyID, publicBaseURL: publicBaseURL, linkDays: linkDays)
    }

    func configuration(linkDays: Int = 7, publicBaseURL: String = "") throws -> ShareConfiguration {
        try ShareConfiguration(preferences: preferences(linkDays: linkDays, publicBaseURL: publicBaseURL), secret: Self.secret)
    }

    // MARK: - What a test reads and scripts

    var requests: [Request] { state.withLock { $0.requests } }

    func object(at path: String) -> Object? { state.withLock { $0.objects[path] } }

    var openUploads: Int { state.withLock { $0.uploads.count } }

    func put(_ data: Data, at path: String) { state.withLock { $0.objects[path] = Object(data: data, contentType: nil) } }

    /// The server's clock: a request signed more than 15 minutes away from it fails with `RequestTimeTooSkewed`.
    func setServerTime(_ date: Date?) { state.withLock { $0.serverTime = date } }

    /// The next requests that match get `replies`, one each, before the fake answers as S3 again. `matches` gets the
    /// request and its ordinal (1 for the first request this fake saw).
    func script(when matches: @escaping @Sendable (Request, Int) -> Bool, _ replies: Reply...) {
        state.withLock { $0.rules.append(Rule(matches: matches, replies: replies)) }
    }

    func script(request ordinal: Int, _ replies: Reply...) {
        state.withLock { $0.rules.append(Rule(matches: { $1 == ordinal }, replies: replies)) }
    }

    // MARK: - Answering

    fileprivate static func fake(for url: URL) -> FakeS3? {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedHost?.lowercased() else {
            return nil
        }
        let key = url.port.map { "\(host):\($0)" } ?? host
        return registry.withLock { $0[key] }
    }

    fileprivate struct Answer {
        var status: Int
        var body: Data
        var headers: [String: String]
    }

    fileprivate enum Outcome {
        case answer(Answer)
        case failure(URLError.Code)
        case hang
    }

    fileprivate func receive(_ urlRequest: URLRequest, body: Data) -> Outcome {
        let url = urlRequest.url!
        var headers: [String: String] = [:]
        for (name, value) in urlRequest.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }
        let method = urlRequest.httpMethod ?? "GET"
        let path = url.path(percentEncoded: true)
        let request = Request(
            method: method, url: url, path: path.isEmpty ? "/" : path, query: url.query(percentEncoded: true),
            headers: headers, body: body,
            signatureMatches: signatureMatches(method: method, url: url, headers: headers, body: body))
        return state.withLock { state -> Outcome in
            state.requests.append(request)
            let ordinal = state.requests.count
            if let index = state.rules.firstIndex(where: { !$0.replies.isEmpty && $0.matches(request, ordinal) }) {
                let reply = state.rules[index].replies.removeFirst()
                switch reply {
                case .status(let status, let body, let headers):
                    return .answer(Answer(status: status, body: Data(body.utf8), headers: headers))
                case .error(let status, let code, let date):
                    return .answer(Self.error(status, code, date: date))
                case .networkFailure(let code): return .failure(code)
                case .hang: return .hang
                }
            }
            return .answer(answer(request, in: &state))
        }
    }

    private func answer(_ request: Request, in state: inout State) -> Answer {
        let items = request.queryItems
        let presigned = items["X-Amz-Signature"] != nil
        let anonymous = request.headers["authorization"] == nil && !presigned
        if let serverTime = state.serverTime, !anonymous {
            let signedAt = (request.headers["x-amz-date"] ?? items["X-Amz-Date"]).flatMap(Self.parseAmzDate)
            if signedAt.map({ abs($0.timeIntervalSince(serverTime)) > 15 * 60 }) ?? true {
                return Self.error(403, "RequestTimeTooSkewed", date: serverTime)
            }
            if presigned, let signedAt, let expires = items["X-Amz-Expires"].flatMap(TimeInterval.init),
                serverTime > signedAt.addingTimeInterval(expires)
            {
                return Self.error(403, "AccessDenied")
            }
        }
        if anonymous {
            guard isPublic, request.method == "GET" else { return Self.error(403, "AccessDenied") }
        } else {
            guard request.signatureMatches else { return Self.error(403, "SignatureDoesNotMatch") }
        }
        return Self.storageAnswer(request, items: items.filter { !$0.key.hasPrefix("X-Amz-") }, in: &state)
    }

    private static func storageAnswer(_ request: Request, items: [String: String], in state: inout State) -> Answer {
        let path = request.objectPath
        switch (request.method, items["uploads"] != nil, items["uploadId"]) {
        case ("POST", true, nil):
            state.uploadCount += 1
            // An id with what a query must encode: a bare "+" would come back as a space.
            let id = "\(state.uploadCount)~iCw+lDY8/VoNMv1ZQ="
            state.uploads[id] = Upload(path: path, contentType: request.headers["content-type"])
            return xml(
                200,
                "<InitiateMultipartUploadResult><Bucket>bucket</Bucket><Key>\(path)</Key><UploadId>\(id)</UploadId>"
                    + "</InitiateMultipartUploadResult>")
        case ("PUT", false, let id?):
            guard let number = request.partNumber, (1...10_000).contains(number) else { return error(400, "InvalidArgument") }
            guard state.uploads[id]?.path == path else { return error(404, "NoSuchUpload") }
            state.uploads[id]?.parts[number] = request.body
            return Answer(status: 200, body: Data(), headers: ["ETag": etag(request.body)])
        case ("POST", false, let id?):
            guard let upload = state.uploads[id], upload.path == path else { return error(404, "NoSuchUpload") }
            let listed = completedParts(request.body)
            guard !listed.isEmpty, listed.map(\.number) == Array(1...listed.count),
                listed.allSatisfy({ upload.parts[$0.number].map(etag) == $0.etag })
            else { return error(400, "InvalidPart") }
            var data = Data()
            for part in listed { data += upload.parts[part.number]! }
            state.objects[path] = Object(data: data, contentType: upload.contentType)
            state.uploads[id] = nil
            return xml(
                200,
                "<CompleteMultipartUploadResult><Location>https://x\(path)</Location><Bucket>bucket</Bucket>"
                    + "<Key>\(path)</Key><ETag>\"\(listed.count)\"</ETag></CompleteMultipartUploadResult>")
        case ("DELETE", false, let id?):
            guard state.uploads.removeValue(forKey: id) != nil else { return error(404, "NoSuchUpload") }
            return Answer(status: 204, body: Data(), headers: [:])
        case ("PUT", false, nil):
            state.objects[path] = Object(data: request.body, contentType: request.headers["content-type"])
            return Answer(status: 200, body: Data(), headers: ["ETag": etag(request.body)])
        case ("GET", false, nil):
            guard let object = state.objects[path] else { return error(404, "NoSuchKey") }
            return Answer(status: 200, body: object.data, headers: ["Content-Type": object.contentType ?? "binary/octet-stream"])
        case ("DELETE", false, nil):
            state.objects[path] = nil
            return Answer(status: 204, body: Data(), headers: [:])
        default:
            return error(400, "InvalidRequest")
        }
    }

    // MARK: - S3's rules, written again for the fake

    /// Checks the `Authorization` header against what arrived: the credential and scope, every `x-amz-*` header signed,
    /// the body's hash, and the signature over the path as it arrived (never re-encoded).
    private func signatureMatches(method: String, url: URL, headers: [String: String], body: Data) -> Bool {
        let query = Self.decodedQueryPairs(url.query(percentEncoded: true))
        if headers["authorization"] == nil, let signature = query.first(where: { $0.0 == "X-Amz-Signature" })?.1 {
            return presignatureMatches(method: method, url: url, query: query, signature: signature)
        }
        guard let authorization = headers["authorization"],
            let date = headers["x-amz-date"].flatMap(Self.parseAmzDate),
            let payloadHash = headers["x-amz-content-sha256"],
            payloadHash == Self.hex(SHA256.hash(data: body)),
            let signedList = Self.field("SignedHeaders=", in: authorization),
            let credential = Self.field("Credential=", in: authorization),
            credential == "\(credentials.accessKeyID)/\(SigV4.amzDate(date).prefix(8))/\(region)/s3/aws4_request"
        else { return false }
        let signedNames = signedList.split(separator: ";").map(String.init)
        guard signedNames.contains("host"),
            headers.keys.filter({ $0.hasPrefix("x-amz-") }).allSatisfy(signedNames.contains)
        else { return false }
        var signed: [String: String] = [:]
        for name in signedNames {
            if name == "host" {
                let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedHost ?? ""
                signed[name] = url.port.map { "\(host):\($0)" } ?? host
            } else {
                guard let value = headers[name] else { return false }
                signed[name] = value
            }
        }
        let path = url.path(percentEncoded: true)
        let expected = SigV4(credentials: credentials, region: region).authorization(
            method: method, encodedPath: path.isEmpty ? "/" : path, query: query, headers: signed,
            payloadHash: payloadHash, date: date)
        return expected == authorization
    }

    /// A presigned URL (`X-Amz-*` in the query, only `host` signed, `UNSIGNED-PAYLOAD`) signed again from what arrived.
    private func presignatureMatches(method: String, url: URL, query: [(String, String)], signature: String) -> Bool {
        let values = Dictionary(query, uniquingKeysWith: { first, _ in first })
        guard values["X-Amz-Algorithm"] == SigV4.algorithm, values["X-Amz-SignedHeaders"] == "host",
            let date = values["X-Amz-Date"].flatMap(Self.parseAmzDate),
            let expires = values["X-Amz-Expires"].flatMap(Int.init), (1...604_800).contains(expires),
            values["X-Amz-Credential"]
                == "\(credentials.accessKeyID)/\(SigV4.amzDate(date).prefix(8))/\(region)/s3/aws4_request",
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        let rest = query.filter { !$0.0.hasPrefix("X-Amz-") }
        components.percentEncodedQuery = rest.isEmpty ? nil : SigV4.canonicalQuery(rest)
        guard let bare = components.url else { return false }
        let again = SigV4(credentials: credentials, region: region).presignedURL(
            method: method, url: bare, expires: expires, date: date)
        return Self.decodedQuery(again.query(percentEncoded: true))["X-Amz-Signature"] == signature
    }

    private static func field(_ name: String, in authorization: String) -> String? {
        guard let range = authorization.range(of: name) else { return nil }
        return String(authorization[range.upperBound...].prefix { $0 != "," && $0 != " " })
    }

    static func decodedQueryPairs(_ query: String?) -> [(String, String)] {
        guard let query, !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ text: Substring) -> String {
                text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(text)
            }
            return (decode(parts[0]), parts.count > 1 ? decode(parts[1]) : "")
        }
    }

    static func decodedQuery(_ query: String?) -> [String: String] {
        Dictionary(decodedQueryPairs(query), uniquingKeysWith: { first, _ in first })
    }

    private static func completedParts(_ body: Data) -> [(number: Int, etag: String)] {
        let text = String(decoding: body, as: UTF8.self)
        let pattern = /<Part>\s*<PartNumber>(\d+)<\/PartNumber>\s*<ETag>([^<]*)<\/ETag>\s*<\/Part>/
        return text.matches(of: pattern).map { (Int($0.output.1)!, String($0.output.2)) }
    }

    static func etag(_ data: Data) -> String { "\"\(hex(Insecure.MD5.hash(data: data)))\"" }

    static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func parseAmzDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: text)
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private static func xml(_ status: Int, _ body: String) -> Answer {
        Answer(
            status: status, body: Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + body).utf8),
            headers: ["Content-Type": "application/xml"])
    }

    private static func error(_ status: Int, _ code: String, date: Date? = nil) -> Answer {
        var answer = xml(status, "<Error><Code>\(code)</Code><Message>\(code)</Message><RequestId>1</RequestId></Error>")
        if let date { answer.headers["Date"] = httpDate(date) }
        return answer
    }
}

/// The `URLProtocol` behind `FakeS3.session(host:)`: it takes every request, so none reaches the network.
final class FakeS3Protocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let fake = FakeS3.fake(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch fake.receive(request, body: Self.body(of: request)) {
        case .answer(let answer):
            var headers = answer.headers
            headers["Content-Length"] = "\(answer.body.count)"
            let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !answer.body.isEmpty { client?.urlProtocol(self, didLoad: answer.body) }
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    /// An upload task hands its body over as a stream, never as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
