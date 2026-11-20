// SPDX-License-Identifier: GPL-3.0-or-later

/// The title and the summary of a project (fases 4 y 5 design §4.1): `EditDocument.info`, from version 5. The share
/// page, the description for YouTube and the AI of phase 5 read and write them; nothing draws them. `nil` in the
/// document is the legacy, a project without either, left out of the JSON.
public struct ProjectInfo: Codable, Equatable, Sendable {
    /// Up to `titleLimit` characters; `""` has none.
    public var title: String
    /// Up to `summaryLimit` characters, line breaks included; `""` has none.
    public var summary: String

    /// The longest title, in characters (`String.count`): a longer one is a `DocumentProblem`.
    public static let titleLimit = 200
    /// The longest summary, in characters (`String.count`): a longer one is a `DocumentProblem`.
    public static let summaryLimit = 2000

    public init(title: String, summary: String) {
        self.title = title
        self.summary = summary
    }
}
