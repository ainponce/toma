// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// An access key: its id and its secret. The secret is never printed: `description`, `debugDescription` and the mirror
/// (`dump`, `String(reflecting:)`) show the id alone, so a configuration, a client or an error that holds one cannot leak
/// it to a log.
public struct S3Credentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessKeyID: String
    let secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }

    public var description: String { "S3Credentials(accessKeyID: \(accessKeyID), secretAccessKey: <hidden>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["accessKeyID": accessKeyID, "secretAccessKey": "<hidden>"], displayStyle: .struct)
    }
}

/// AWS Signature Version 4, written by hand with CryptoKit (design §3, §8.1): the `Authorization` header of a request
/// and the query of a presigned URL. What it signs follows plan 5a, decision 6: a request's body is always hashed (never
/// `UNSIGNED-PAYLOAD` but on a presigned GET); the signed headers are `host` (with its port when it is not its scheme's),
/// `x-amz-*` and `content-type` when there is one; each segment of a path is encoded once, and the path is never
/// normalized (S3's rule).
public struct SigV4: Sendable, CustomStringConvertible {
    public static let algorithm = "AWS4-HMAC-SHA256"
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    let credentials: S3Credentials
    let region: String
    let service: String

    public init(credentials: S3Credentials, region: String, service: String = "s3") {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    public var description: String { "SigV4(\(credentials), region: \(region), service: \(service))" }

    // MARK: - The pieces

    /// `20130524T000000Z`: the date in UTC, to the second (cut, never rounded), whatever the process's time zone.
    public static func amzDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String {
            let value = value ?? 0
            return value < 10 ? "0\(value)" : "\(value)"
        }
        let year = String(parts.year ?? 0)
        return "\(String(repeating: "0", count: max(0, 4 - year.count)))\(year)\(two(parts.month))\(two(parts.day))"
            + "T\(two(parts.hour))\(two(parts.minute))\(two(parts.second))Z"
    }

    /// RFC 3986 encoding as SigV4 wants it: the unreserved characters (`A–Z a–z 0–9 - _ . ~`) stay, every other byte of the
    /// UTF-8 is `%XX` in upper case; `/` stays only when `encodeSlash` is false (an object key in a path).
    public static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
        var encoded = ""
        encoded.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."),
                UInt8(ascii: "~"):
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: "/") where !encodeSlash:
                encoded.append("/")
            default:
                encoded.append("%")
                encoded.append(hexDigits[Int(byte >> 4)])
                encoded.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return encoded
    }

    private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    /// The canonical query: every name and value encoded (a `/` too), sorted by name and then by value, `name=value`
    /// joined with `&`. A name without a value is `name=` (`uploads=`).
    public static func canonicalQuery(_ items: [(String, String)]) -> String {
        // Encoded text is ASCII, so `<` is the byte order SigV4 sorts by.
        let encoded: [(name: String, value: String)] = items.map { item in
            (uriEncode(item.0, encodeSlash: true), uriEncode(item.1, encodeSlash: true))
        }
        let sorted = encoded.sorted { left, right in
            left.name == right.name ? left.value < right.value : left.name < right.name
        }
        return sorted.map { item in item.name + "=" + item.value }.joined(separator: "&")
    }

    /// The canonical request of `headers` (every one is signed): names in lower case, sorted, values trimmed with their
    /// inner runs of spaces made one; `signedHeaders` is the names joined with `;`.
    public static func canonicalRequest(
        method: String, encodedPath: String, query: [(String, String)], headers: [String: String], payloadHash: String
    ) -> (text: String, signedHeaders: String) {
        var canonical: [String: String] = [:]
        for (name, value) in headers {
            let name = name.lowercased()
            let value = trimmed(value)
            // Two spellings of one header become one line, values joined by commas as HTTP does.
            canonical[name] = canonical[name].map { "\($0),\(value)" } ?? value
        }
        let names = canonical.keys.sorted()
        let headerLines = names.map { "\($0):\(canonical[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let text = [
            method.uppercased(), encodedPath.isEmpty ? "/" : encodedPath, canonicalQuery(query), headerLines,
            signedHeaders, payloadHash,
        ].joined(separator: "\n")
        return (text, signedHeaders)
    }

    private static func trimmed(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    public static func signingKey(secret: String, dateStamp: String, region: String, service: String) -> SymmetricKey {
        let date = hmac(SymmetricKey(data: Data("AWS4\(secret)".utf8)), dateStamp)
        let regionKey = hmac(SymmetricKey(data: date), region)
        let serviceKey = hmac(SymmetricKey(data: regionKey), service)
        return SymmetricKey(data: hmac(SymmetricKey(data: serviceKey), "aws4_request"))
    }

    public func stringToSign(canonicalRequest: String, date: Date) -> String {
        [
            Self.algorithm, Self.amzDate(date), scope(date),
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")
    }

    public func signature(stringToSign: String, date: Date) -> String {
        let key = Self.signingKey(
            secret: credentials.secretAccessKey, dateStamp: Self.dateStamp(date), region: region, service: service)
        return Self.hex(Self.hmac(key, stringToSign))
    }

    /// `AWS4-HMAC-SHA256 Credential=<id>/<scope>, SignedHeaders=<names>, Signature=<hex>`, signing every one of `headers`.
    public func authorization(
        method: String, encodedPath: String, query: [(String, String)], headers: [String: String], payloadHash: String,
        date: Date
    ) -> String {
        let canonical = Self.canonicalRequest(
            method: method, encodedPath: encodedPath, query: query, headers: headers, payloadHash: payloadHash)
        let signature = signature(stringToSign: stringToSign(canonicalRequest: canonical.text, date: date), date: date)
        return "\(Self.algorithm) Credential=\(credentials.accessKeyID)/\(scope(date)), "
            + "SignedHeaders=\(canonical.signedHeaders), Signature=\(signature)"
    }

    // MARK: - Requests and links

    /// `request` with `x-amz-date`, `x-amz-content-sha256` and `Authorization` set. It signs `host` from the URL (the port
    /// too when it is not the scheme's: what `URLSession` sends), the request's `x-amz-*` headers, and `content-type`
    /// and `content-md5` when the request has them. The path is the URL's own, each segment encoded once.
    public func signed(_ request: URLRequest, payloadHash: String, date: Date) -> URLRequest {
        var request = request
        guard let url = request.url else { return request }
        request.setValue(Self.amzDate(date), forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        var headers = ["host": Self.hostHeader(url)]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let name = name.lowercased()
            if name.hasPrefix("x-amz-") || name == "content-type" || name == "content-md5" { headers[name] = value }
        }
        request.setValue(
            authorization(
                method: request.httpMethod ?? "GET", encodedPath: Self.encodedPath(url), query: Self.queryItems(url),
                headers: headers, payloadHash: payloadHash, date: date),
            forHTTPHeaderField: "Authorization")
        return request
    }

    /// `url` presigned for `method`: the `X-Amz-*` items of a query-string signature (only `host` signed, the payload
    /// `UNSIGNED-PAYLOAD`), in canonical order, and `X-Amz-Signature` last. `expires` is in seconds (SigV4 allows 7 days).
    public func presignedURL(method: String, url: URL, expires: Int, date: Date) -> URL {
        let query =
            Self.queryItems(url) + [
                ("X-Amz-Algorithm", Self.algorithm),
                ("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope(date))"),
                ("X-Amz-Date", Self.amzDate(date)),
                ("X-Amz-Expires", String(expires)),
                ("X-Amz-SignedHeaders", "host"),
            ]
        let canonical = Self.canonicalRequest(
            method: method, encodedPath: Self.encodedPath(url), query: query, headers: ["host": Self.hostHeader(url)],
            payloadHash: Self.unsignedPayload)
        let signature = signature(stringToSign: stringToSign(canonicalRequest: canonical.text, date: date), date: date)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.percentEncodedQuery = Self.canonicalQuery(query) + "&X-Amz-Signature=\(signature)"
        return components.url ?? url
    }

    // MARK: - Helpers

    /// The `Host` header `URLSession` sends for `url`: the host as written (an IPv6 address in brackets), with the port
    /// when there is one that is not the scheme's.
    static func hostHeader(_ url: URL) -> String {
        let host = bracketedHost(url).lowercased()
        guard let port = url.port else { return host }
        let scheme = url.scheme?.lowercased()
        if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) { return host }
        return "\(host):\(port)"
    }

    /// The URL's host as written in it: an IPv6 address keeps its brackets (`URL.host` drops them).
    static func bracketedHost(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedHost ?? url.host(percentEncoded: true) ?? ""
    }

    /// The URL's path, each segment encoded once as SigV4 encodes it (what S3 computes from what it receives): a path
    /// written by `ShareConfiguration.objectURL(key:)` is taken as it is; a character left bare, such as `$`, is encoded.
    /// Segments are never removed or merged: `.` and `..` stay (S3 does not normalize). "/" when the path is empty.
    static func encodedPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: true)
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in uriEncode(String(segment).removingPercentEncoding ?? String(segment), encodeSlash: true) }
            .joined(separator: "/")
    }

    /// The URL's query items, decoded (a name without a value has ""); the canonical query encodes them again.
    static func queryItems(_ url: URL) -> [(String, String)] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems else {
            return []
        }
        return items.map { item in
            (item.name.removingPercentEncoding ?? item.name, (item.value ?? "").removingPercentEncoding ?? item.value ?? "")
        }
    }

    private func scope(_ date: Date) -> String { "\(Self.dateStamp(date))/\(region)/\(service)/aws4_request" }

    private static func dateStamp(_ date: Date) -> String { String(amzDate(date).prefix(8)) }

    private static func hmac(_ key: SymmetricKey, _ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key))
    }

    private static let lowerHexDigits: [Character] = Array("0123456789abcdef")

    /// Lower-case hex, as SigV4 writes hashes and signatures.
    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        var text = ""
        for byte in bytes {
            text.append(lowerHexDigits[Int(byte >> 4)])
            text.append(lowerHexDigits[Int(byte & 0x0F)])
        }
        return text
    }
}
