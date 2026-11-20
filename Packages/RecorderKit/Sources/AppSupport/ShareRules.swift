// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Sharing

/// The last MP4 an editor exported in this session (plan 5a, decision 11): what it was made of and how, so "Share" can
/// upload it instead of exporting the same video again.
public struct RememberedExport: Equatable, Sendable {
    public var url: URL
    /// `ShareInputs.documentHash` of the document exported.
    public var documentHash: String
    public var outputSize: SIMD2<Int>
    public var framesPerSecond: Int
    /// `ExportCodec`'s raw value: `h264`, `hevc`, `proRes422`…
    public var codec: String
    /// The whole video, not a range of it.
    public var wholeVideo: Bool
    /// The file's size when it was written: another size is another file.
    public var bytes: Int64
    /// The chapters the file carries (`ExportSettings.chapters`): none when "Chapters in the File" was off.
    public var chapters: [Chapter]

    public init(
        url: URL, documentHash: String, outputSize: SIMD2<Int>, framesPerSecond: Int, codec: String, wholeVideo: Bool,
        bytes: Int64, chapters: [Chapter] = []
    ) {
        self.url = url
        self.documentHash = documentHash
        self.outputSize = outputSize
        self.framesPerSecond = framesPerSecond
        self.codec = codec
        self.wholeVideo = wholeVideo
        self.bytes = bytes
        self.chapters = chapters
    }
}

/// The editor's and Settings ▸ Share's rules of sharing (plan 5a, decisions 11 and 14; design §8.4), apart from their
/// views.
public enum ShareRules {
    /// The codec of the video a share uploads (`ExportCodec.h264`'s raw value).
    public static let sharedCodec = "h264"

    /// `export`'s file, when it is the video `request` asks for: the same document (`documentHash`), H.264 of the same
    /// size and frame rate, the whole video with the same chapters, and still `bytesNow` the size it was written with
    /// (`nil`: it is gone). `nil` otherwise: the share exports it anew.
    public static func reusable(_ export: RememberedExport?, for request: ShareJob.VideoRequest, bytesNow: Int64?) -> URL? {
        guard let export, export.documentHash == request.documentHash, export.codec == sharedCodec,
            export.outputSize == request.outputSize, export.framesPerSecond == request.framesPerSecond,
            export.wholeVideo, export.chapters == request.chapters, let bytesNow, bytesNow == export.bytes
        else { return nil }
        return export.url
    }

    /// What is said of a link (design §8.4): public, which never expires, or the instant a signed one expires, or expired.
    public enum LinkNote: Equatable, Sendable {
        case permanent
        case expires(Date)
        case expired(Date)
    }

    /// The note of `record` at `now`: a signed link no longer works from the second it expires
    /// (`ShareRecord.hasExpired(at:)`).
    public static func note(for record: ShareRecord, now: Date) -> LinkNote {
        guard let expiresAt = record.expiresAt else { return .permanent }
        return record.hasExpired(at: now) ? .expired(expiresAt) : .expires(expiresAt)
    }

    /// `preferences` with `provider` chosen (decision 14): its template's region and endpoint, unless the endpoint was
    /// written by hand (one that is not empty and not in the shape of a template, `isTemplateEndpoint`), which stays. R2's
    /// endpoint has the person's account in it and "Other" has none, so theirs is left empty for the person to write (the
    /// field shows the template). Choosing the service there is changes nothing.
    public static func choosing(_ provider: ShareProvider, in preferences: SharePreferences) -> SharePreferences {
        guard provider != preferences.provider else { return preferences }
        var chosen = preferences
        chosen.provider = provider
        chosen.region = provider.defaultRegion
        if isTemplateEndpoint(preferences.endpoint) {
            chosen.endpoint = templateEndpoint(of: provider, region: provider.defaultRegion)
        }
        return chosen
    }

    /// `preferences` with `region` typed: for S3 and B2, whose endpoint follows from the region, an endpoint in the shape
    /// of their template (or empty) moves to the region's, once the region can be part of a host name; an endpoint written
    /// by hand stays.
    public static func changingRegion(_ region: String, in preferences: SharePreferences) -> SharePreferences {
        var changed = preferences
        changed.region = region
        if isTemplateEndpoint(preferences.endpoint), let endpoint = preferences.provider.endpoint(region: region) {
            changed.endpoint = endpoint
        }
        return changed
    }

    /// The endpoint a service's template fills in: S3's and B2's of `region`, MinIO's local one; "" for R2 and "Other".
    static func templateEndpoint(of provider: ShareProvider, region: String) -> String {
        if let endpoint = provider.endpoint(region: region) { return endpoint }
        return provider == .minio ? provider.endpointTemplate : ""
    }

    /// Whether `endpoint` is one a template filled in, not one written by hand: empty, MinIO's local one, or S3's or
    /// B2's of some region (`https://s3.<region>.amazonaws.com`, `https://s3.<region>.backblazeb2.com`, the region one
    /// label of `a–z 0–9 -`).
    static func isTemplateEndpoint(_ endpoint: String) -> Bool {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !endpoint.isEmpty, endpoint != ShareProvider.minio.endpointTemplate else { return true }
        for suffix in [".amazonaws.com", ".backblazeb2.com"] {
            let prefix = "https://s3."
            guard endpoint.hasPrefix(prefix), endpoint.hasSuffix(suffix),
                endpoint.count > prefix.count + suffix.count
            else { continue }
            let region = endpoint.dropFirst(prefix.count).dropLast(suffix.count)
            if region.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) { return true }
        }
        return false
    }
}
