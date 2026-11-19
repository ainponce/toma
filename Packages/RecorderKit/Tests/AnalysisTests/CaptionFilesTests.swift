// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

@testable import Analysis

private func caption(_ text: String, _ start: Int64, _ end: Int64) -> Caption {
    let lines = text.split(separator: "\n").map { line in
        line.split(separator: " ").map { CaptionWord(ref: TranscriptWordRef(take: 0, word: 0), text: String($0), output: start..<end) }
    }
    return Caption(output: start..<end, lines: lines, text: text)
}

@Suite struct CaptionFilesTests {
    private let two = [caption("Hola mundo", 1_000_000_000, 2_300_000_000), caption("Segundo\nrenglón", 3_000_000_000, 4_000_000_000)]

    @Test func srtTimesAreTheCaptionsOnes() {
        #expect(
            CaptionFiles.srt(two)
                == "1\n00:00:01,000 --> 00:00:02,300\nHola mundo\n\n2\n00:00:03,000 --> 00:00:04,000\nSegundo\nrenglón\n")
        // 1 h 2 min 3.4567 s.
        let late = caption("x", 3_723_456_700_000, 3_724_000_000_000)
        #expect(CaptionFiles.srt([late]).hasPrefix("1\n01:02:03,457 --> 01:02:04,000\n"))
    }

    @Test func vttIsWebVTT() {
        #expect(
            CaptionFiles.vtt(two)
                == "WEBVTT\n\n00:00:01.000 --> 00:00:02.300\nHola mundo\n\n00:00:03.000 --> 00:00:04.000\nSegundo\nrenglón\n")
        // An end that rounds to its start goes 1 ms after it.
        let tiny = caption("a", 1_000_000_000, 1_000_200_000)
        #expect(CaptionFiles.vtt([tiny]).contains("00:00:01.000 --> 00:00:01.001"))
        #expect(CaptionFiles.srt([tiny]).contains("00:00:01,000 --> 00:00:01,001"))
    }

    @Test func vttEscapesMarkup() {
        #expect(CaptionFiles.vtt([caption("a<b & c", 0, 1_000_000_000)]).contains("a&lt;b &amp; c"))
    }

    @Test func noCaptionsIsAnEmptyFile() {
        #expect(CaptionFiles.srt([]) == "")
        #expect(CaptionFiles.vtt([]) == "WEBVTT\n")
    }
}
