// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// What `sensitiveScan-1` found in a take, and what it was found in: the JSON of its cache file
/// (`scan/<take>-sensitiveScan-1.json`, plan decision 7). The texts are only ever masked (`PrivacyFinding.masked`).
///
/// It holds while `algorithm`, `version`, `take`, `segments` and `samples` are what a new scan would have: the same
/// algorithm on the same bytes of the take's screen, looking at the same frames.
public struct ScanResult: Codable, Equatable, Sendable {
    /// The version of this layout.
    public static let currentVersion = 1

    /// `SensitiveDetectors.id`, `sensitiveScan-1`.
    public var algorithm: String
    /// By start.
    public var findings: [PrivacyFinding]
    /// Which frames were looked at (`SensitiveScan.fingerprint`): the document decides which screen is shown when.
    public var samples: String
    /// The identities of the take's screen segments as the scan began, `<track>/<SegmentIdentity.name>` each, in the
    /// manifest's order (`SensitiveScanJob.segmentNames`).
    public var segments: [String]
    public var take: String
    public var version: Int

    public init(
        algorithm: String, findings: [PrivacyFinding], samples: String, segments: [String], take: String, version: Int
    ) {
        self.algorithm = algorithm
        self.findings = findings
        self.samples = samples
        self.segments = segments
        self.take = take
        self.version = version
    }
}
