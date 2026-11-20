// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The text to paste in YouTube's description (milestone 5b, plan decision 14).
public enum YouTubeDescription {
    /// The summary, a blank line and the chapters' lines (`Chapters.youTubeText`); either alone if the other has nothing;
    /// `""` with neither. `chapters` is already `Chapters.list(...)`, with its intro if it needs one.
    public static func text(summary: String?, chapters: [Chapter], duration: Int64) -> String {
        let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lines = Chapters.youTubeText(chapters, duration: duration)
        return [summary, lines].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
