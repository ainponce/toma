// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How an object's URL is written: `<endpoint>/<bucket>/<key>` (path) or `<bucket>.<endpoint host>/<key>` (virtual host).
public enum S3Addressing: Sendable {
    case path, virtualHosted
}

/// Why Settings ▸ Share cannot make a configuration yet (plan 5a, decision 5; design §8.4).
public enum ShareConfigurationProblem: Error, Equatable, Sendable {
    case missingEndpoint
    /// Not an `http(s)://host[:port]` URL: another scheme, a path, a query or a user in it.
    case invalidEndpoint
    /// `http://` to a host other than `localhost`, `127.0.0.1` or `::1`.
    case insecureEndpoint
    case missingBucket
    /// A `/`, a space, `..` or a character a bucket name cannot have.
    case invalidBucket
    /// A `.` or `..` segment.
    case invalidPrefix
    case missingAccessKey
    case missingSecret
    case invalidPublicURL
    /// `http://` to a host other than `localhost`, `127.0.0.1` or `::1`.
    case insecurePublicURL
    /// Not lower-case letters, digits and `-`: it would break the signature's scope.
    case invalidRegion
    /// A space, `/`, `,`, `=`, `;` or a character outside printable ASCII: it would break the `Credential=` field.
    case invalidAccessKey
}

/// What the S3 client needs, checked and normalized from Settings ▸ Share and the secret from the Keychain. Printing it
/// never shows the secret (`S3Credentials` hides it).
public struct ShareConfiguration: Sendable {
    /// Scheme, host and port; no path.
    public let endpoint: URL
    public let region: String
    public let credentials: S3Credentials
    /// The addressing used: the service's, but path style for an S3 bucket that is not one DNS label of `a–z 0–9 -` (a
    /// dot breaks the TLS wildcard; capitals and `_` are no host name).
    public let addressing: S3Addressing
    /// Not empty, without `/`, spaces or `..`.
    public let bucket: String
    /// "" or ends with "/"; no "/" at the start, no empty, `.` or `..` segments.
    public let prefix: String
    /// The public address the links start with, without a trailing "/"; `nil`: signed links.
    public let publicBaseURL: URL?
    /// How long a signed link lasts, in seconds: 86 400 × `linkDays` clamped to 1…7.
    public let linkLifetime: Int

    public init(preferences: SharePreferences, secret: String) throws(ShareConfigurationProblem) {
        let checked = Self.check(preferences, hasSecret: !secret.isEmpty)
        if let problem = checked.problems.first { throw problem }
        guard let endpoint = checked.endpoint, let bucket = checked.bucket, let prefix = checked.prefix else {
            throw .missingEndpoint
        }
        self.endpoint = endpoint
        let region = preferences.region.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region.isEmpty ? preferences.provider.defaultRegion : region
        self.credentials = S3Credentials(
            accessKeyID: preferences.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines), secretAccessKey: secret)
        self.addressing = Self.isLowerLabel(bucket) ? preferences.provider.addressing : .path
        self.bucket = bucket
        self.prefix = prefix
        self.publicBaseURL = checked.publicBaseURL
        self.linkLifetime = 86_400 * min(max(preferences.linkDays, 1), 7)
    }

    /// Everything that keeps `preferences` from making a configuration, in the order of the settings' fields.
    public static func problems(in preferences: SharePreferences, hasSecret: Bool) -> [ShareConfigurationProblem] {
        check(preferences, hasSecret: hasSecret).problems
    }

    /// The object's URL: each segment of `key` encoded once (RFC 3986, as SigV4 signs it).
    public func objectURL(key: String) -> URL {
        let encodedKey = SigV4.uriEncode(key, encodeSlash: false)
        let scheme = endpoint.scheme ?? "https"
        let host = SigV4.bracketedHost(endpoint)
        let port = endpoint.port.map { ":\($0)" } ?? ""
        switch addressing {
        case .path:
            return URL(string: "\(scheme)://\(host)\(port)/\(bucket)/\(encodedKey)")!
        case .virtualHosted:
            return URL(string: "\(scheme)://\(bucket).\(host)\(port)/\(encodedKey)")!
        }
    }

    /// `<public base>/<key>`, each segment of `key` encoded once; `nil` without a public base URL.
    public func publicURL(key: String) -> URL? {
        guard let publicBaseURL else { return nil }
        return URL(string: publicBaseURL.absoluteString + "/" + SigV4.uriEncode(key, encodeSlash: false))
    }

    // MARK: - Checks

    private struct Checked {
        var problems: [ShareConfigurationProblem] = []
        var endpoint: URL?
        var bucket: String?
        var prefix: String?
        var publicBaseURL: URL?
    }

    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]", "::1"]

    private static func check(_ preferences: SharePreferences, hasSecret: Bool) -> Checked {
        var checked = Checked()
        switch endpoint(preferences.endpoint) {
        case .success(let url): checked.endpoint = url
        case .failure(let problem): checked.problems.append(problem)
        }
        let region = preferences.region.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isLowerLabel(region) { checked.problems.append(.invalidRegion) }
        switch bucket(preferences.bucket) {
        case .success(let bucket): checked.bucket = bucket
        case .failure(let problem): checked.problems.append(problem)
        }
        switch prefix(preferences.prefix) {
        case .success(let prefix): checked.prefix = prefix
        case .failure(let problem): checked.problems.append(problem)
        }
        let accessKeyID = preferences.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        if accessKeyID.isEmpty {
            checked.problems.append(.missingAccessKey)
        } else if !accessKeyID.unicodeScalars.allSatisfy({ (0x21..<0x7F).contains($0.value) && !"/,=;".unicodeScalars.contains($0) }) {
            checked.problems.append(.invalidAccessKey)
        }
        if !hasSecret { checked.problems.append(.missingSecret) }
        switch publicBase(preferences.publicBaseURL) {
        case .success(let url): checked.publicBaseURL = url
        case .failure(let problem): checked.problems.append(problem)
        }
        return checked
    }

    /// An `http(s)` URL with a host and nothing else but a port (and a lone trailing "/"), rebuilt as
    /// `scheme://host[:port]`.
    private static func endpoint(_ text: String) -> Result<URL, ShareConfigurationProblem> {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.missingEndpoint) }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http", let host = components.percentEncodedHost?.lowercased(), !host.isEmpty,
            components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
            components.percentEncodedQuery == nil, components.percentEncodedFragment == nil,
            components.percentEncodedUser == nil, components.percentEncodedPassword == nil
        else { return .failure(.invalidEndpoint) }
        if scheme == "http" && !localHosts.contains(host) { return .failure(.insecureEndpoint) }
        let port = defaultPortDropped(components.port, scheme: scheme)
        guard let url = URL(string: "\(scheme)://\(host)\(port)") else { return .failure(.invalidEndpoint) }
        return .success(url)
    }

    /// Only `a–z`, `0–9` and `-` (an empty text too): a region, or a bucket that can be a host name's label.
    private static func isLowerLabel(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// `:<port>`, or nothing when there is no port or it is the scheme's own (`URLSession` sends `Host` without it).
    private static func defaultPortDropped(_ port: Int?, scheme: String) -> String {
        guard let port, !(scheme == "https" && port == 443), !(scheme == "http" && port == 80) else { return "" }
        return ":\(port)"
    }

    /// A bucket name as S3-compatible services allow it: letters, digits, `.`, `-` and `_`, never `..`.
    private static func bucket(_ text: String) -> Result<String, ShareConfigurationProblem> {
        let bucket = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty else { return .failure(.missingBucket) }
        let allowed = bucket.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_")
        }
        guard allowed, !bucket.contains("..") else { return .failure(.invalidBucket) }
        return .success(bucket)
    }

    /// The prefix with its empty segments dropped and a "/" at the end: `toma` and `/toma/` are `toma/`, `a//b` is `a/b/`.
    /// A `.` or `..` segment would make a link a browser rewrites, so it is refused.
    private static func prefix(_ text: String) -> Result<String, ShareConfigurationProblem> {
        let segments = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return .failure(.invalidPrefix) }
        return .success(segments.isEmpty ? "" : segments.joined(separator: "/") + "/")
    }

    /// An `https` URL (or `http` to this Mac) with a host and maybe a path, without a query or a fragment; its trailing
    /// "/" is dropped. Empty: no public URL.
    private static func publicBase(_ text: String) -> Result<URL?, ShareConfigurationProblem> {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .success(nil) }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http", let host = components.percentEncodedHost?.lowercased(), !host.isEmpty,
            components.percentEncodedQuery == nil, components.percentEncodedFragment == nil,
            components.percentEncodedUser == nil, components.percentEncodedPassword == nil
        else { return .failure(.invalidPublicURL) }
        if scheme == "http" && !localHosts.contains(host) { return .failure(.insecurePublicURL) }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let port = defaultPortDropped(components.port, scheme: scheme)
        guard let url = URL(string: "\(scheme)://\(host)\(port)\(path)") else { return .failure(.invalidPublicURL) }
        return .success(url)
    }
}
