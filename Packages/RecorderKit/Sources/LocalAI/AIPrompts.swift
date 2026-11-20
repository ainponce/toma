// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the model is told (plan 5b, decision 6): instructions in English, which the system model follows best, naming
/// the language to write in.
public enum AIPrompts {
    /// `bcp47`'s name in English (`es-MX` → "Spanish (Mexico)"); the identifier itself if the system has no name for it.
    public static func languageName(_ bcp47: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: bcp47) ?? bcp47
    }

    public static func chapterInstructions(language: String) -> String {
        let name = languageName(language)
        return """
            You split the transcript of a video into chapters, so a viewer can jump to each topic.
            Each line of the transcript starts with a number and a time in brackets: [number @minutes:seconds].
            Start a chapter only where a new topic begins, not at every sentence. A chapter lasts from 30 seconds to 5 \
            minutes, and the first one starts at the first line.
            For each chapter, give the number in brackets of the line where it starts, and a short title of at most 40 \
            characters that names its topic.
            Use only numbers in brackets from the transcript, and list the chapters in order.
            Write every title in \(name), the language of the transcript. Do not number the titles, do not put them in \
            quotes and do not end them with a period.
            """
    }

    /// `lines` for the chapters: one rendered line per row (`TranscriptLines.text`).
    public static func chapterPrompt(_ lines: [TranscriptLine]) -> String {
        "Transcript:\n" + TranscriptLines.text(lines)
    }

    public static func infoInstructions(_ kind: InfoKind, language: String) -> String {
        let name = languageName(language)
        switch kind {
        case .title:
            return """
                You write the title of a video from what is said in it. You are given its transcript, or the summaries of \
                its parts in order.
                Write one title of at most 70 characters that tells what the video is about.
                Write it in \(name), the language of the video. Do not put it in quotes and do not end it with a period.
                """
        case .summary:
            return """
                You write the description of a video from what is said in it. You are given its transcript, or the \
                summaries of its parts in order.
                Write a summary of 2 to 4 sentences that tells what the video covers, in plain sentences, without a title, \
                a list or quotes.
                Write it in \(name), the language of the video.
                """
        case .partSummary:
            return """
                You summarize one part of the transcript of a video.
                Write 2 sentences that tell what this part covers, in plain sentences, without a title, a list or quotes.
                Write them in \(name), the language of the video.
                """
        }
    }

    /// `lines` for a title or a summary: their words, one line per row, without numbers.
    static func infoPrompt(_ lines: [TranscriptLine]) -> String {
        "Transcript:\n" + lines.map(\.text).joined(separator: "\n")
    }

    /// The summaries of the parts, in order, for the title or the summary of a long transcript (decision 7).
    static func infoPrompt(summaries: [String]) -> String {
        "Summaries of the parts of the video, in order:\n"
            + summaries.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
    }
}
