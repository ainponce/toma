// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The storage service "Share Link" uploads to (phase 5, milestone 5a). Every one speaks the S3 API; they differ in how
/// the endpoint and the region are written.
public enum ShareProvider: String, Codable, Sendable, CaseIterable {
    case r2, s3, b2, minio, other
}

/// Where "Share Link" uploads and how its link lasts (phase 5 design §8): everything but the secret key, which lives in the
/// Keychain, never here. A field missing from what was saved, or that this version cannot read, takes its default.
public struct SharePreferences: Codable, Equatable, Sendable {
    public var provider: ShareProvider = .r2
    /// The service's endpoint, a URL; empty until set.
    public var endpoint: String = ""
    /// The region the requests are signed for: `auto` for R2.
    public var region: String = "auto"
    public var bucket: String = ""
    /// What every uploaded object's key starts with.
    public var prefix: String = "toma/"
    /// The access key's id (not the secret).
    public var accessKeyID: String = ""
    /// The public address the links start with, when the bucket is served from one; empty: signed links.
    public var publicBaseURL: String = ""
    /// How many days a signed link lasts.
    public var linkDays: Int = 7

    public init(
        provider: ShareProvider = .r2, endpoint: String = "", region: String = "auto", bucket: String = "",
        prefix: String = "toma/", accessKeyID: String = "", publicBaseURL: String = "", linkDays: Int = 7
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
        self.accessKeyID = accessKeyID
        self.publicBaseURL = publicBaseURL
        self.linkDays = linkDays
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SharePreferences()
        provider = (try? container.decodeIfPresent(ShareProvider.self, forKey: .provider)) ?? defaults.provider
        endpoint = (try? container.decodeIfPresent(String.self, forKey: .endpoint)) ?? defaults.endpoint
        region = (try? container.decodeIfPresent(String.self, forKey: .region)) ?? defaults.region
        bucket = (try? container.decodeIfPresent(String.self, forKey: .bucket)) ?? defaults.bucket
        prefix = (try? container.decodeIfPresent(String.self, forKey: .prefix)) ?? defaults.prefix
        accessKeyID = (try? container.decodeIfPresent(String.self, forKey: .accessKeyID)) ?? defaults.accessKeyID
        publicBaseURL = (try? container.decodeIfPresent(String.self, forKey: .publicBaseURL)) ?? defaults.publicBaseURL
        linkDays = (try? container.decodeIfPresent(Int.self, forKey: .linkDays)) ?? defaults.linkDays
    }
}

/// Each service's template (plan 5a, decision 5): what Settings ▸ Share fills in when the service changes, and how its
/// objects are addressed.
extension ShareProvider {
    /// The region a new configuration of this service signs for.
    public var defaultRegion: String {
        switch self {
        case .r2: "auto"
        case .b2: "us-west-004"
        case .s3, .minio, .other: "us-east-1"
        }
    }

    /// What the endpoint field shows while it is empty: the shape of this service's endpoint.
    public var endpointTemplate: String {
        switch self {
        case .r2: "https://<ACCOUNT_ID>.r2.cloudflarestorage.com"
        case .s3: "https://s3.<REGION>.amazonaws.com"
        case .b2: "https://s3.<REGION>.backblazeb2.com"
        case .minio: "http://localhost:9000"
        case .other: ""
        }
    }

    /// The endpoint of `region` for the services whose endpoint follows from it (S3 and B2); `nil` for the others, whose
    /// endpoint is written by hand, and for a region that cannot be part of a host name.
    public func endpoint(region: String) -> String? {
        let region = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !region.isEmpty, region.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return nil
        }
        switch self {
        case .s3: return "https://s3.\(region).amazonaws.com"
        case .b2: return "https://s3.\(region).backblazeb2.com"
        case .r2, .minio, .other: return nil
        }
    }

    /// How an object's URL is written: S3 puts the bucket in the host; the others, in the path.
    public var addressing: S3Addressing {
        self == .s3 ? .virtualHosted : .path
    }
}
