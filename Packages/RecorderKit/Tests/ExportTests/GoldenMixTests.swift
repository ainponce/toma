// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Render
import Testing

/// The cases of `GoldenProjects` whose mix the golden file holds, in its order.
private let mixedCases = ["phaseZero", "pausedTake", "twoAudioTracks"]

/// The frames of the mix of `project` at 60 fps, worked out apart from the exporter: its timeline rounded to whole
/// frames of video, at 48 kHz.
private func mixFrames(of project: LoadedProject) -> Int {
    let duration = FrameEvaluator(take: project.take, events: project.events, style: StyleV0(), outputSize: [1280, 720]).duration
    let frames = max(1, Int((duration * 60).rounded()))
    return Int((Double(frames) / 60 * 48_000).rounded())
}

/// Projects of version 1 and 2 without edits sound the same from one version of the export to the next (plan decision
/// 3). It runs only with `TOMA_GOLDEN_FILE` set: the samples the AAC encoder gets at 60 fps
/// (`MP4Exporter.mixSamples(of:)`) of `phaseZero`, `pausedTake` and `twoAudioTracks`, as little-endian Float32, one
/// case after the other, must equal `<TOMA_GOLDEN_FILE>.mix` bit for bit. With `TOMA_GOLDEN_RECORD=1` as well, it
/// writes them to that file instead (`make golden-record`), and never over a file already there. Without the file and
/// without the switch it fails: it never passes without comparing.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_GOLDEN_FILE"] != nil))
func goldenMixMatches() async throws {
    let environment = ProcessInfo.processInfo.environment
    let url = URL(fileURLWithPath: try #require(environment["TOMA_GOLDEN_FILE"]) + ".mix")
    let recording = environment["TOMA_GOLDEN_RECORD"] == "1"
    let exists = FileManager.default.fileExists(atPath: url.path)
    if recording {
        try #require(!exists, "\(url.path) is already there: remove it to record the golden mix again")
    } else {
        try #require(exists, "No golden mix at \(url.path): record it first, with TOMA_GOLDEN_RECORD=1, on the code to compare against")
    }
    var bytes = Data()
    // Where each case starts in `bytes`, and its channels.
    var spans: [(name: String, start: Int, channels: Int)] = []
    try await withTemporaryDirectory { dir in
        for name in mixedCases {
            let project = try await GoldenProjects.make(name, in: dir)
            let samples = try await MP4Exporter.mixSamples(of: project)
            let frames = mixFrames(of: project)
            try #require(
                samples.count == frames || samples.count == 2 * frames, "\(name): \(samples.count) samples for \(frames) frames")
            spans.append((name, bytes.count, samples.count / frames))
            for sample in samples {
                withUnsafeBytes(of: sample.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
            }
        }
    }
    if recording {
        try bytes.write(to: url, options: .withoutOverwriting)
        return
    }
    let golden = try Data(contentsOf: url)
    try #require(golden.count == bytes.count, "\(golden.count) bytes in \(url.path), \(bytes.count) mixed")
    guard golden != bytes else { return }
    let first = try #require(golden.indices.first { golden[$0] != bytes[$0] })
    let span = try #require(spans.last { $0.start <= first })
    let sample = (first - span.start) / MemoryLayout<Float>.size
    let differing = stride(from: 0, to: bytes.count, by: MemoryLayout<Float>.size).reduce(0) {
        $0 + (golden[$1..<$1 + MemoryLayout<Float>.size] != bytes[$1..<$1 + MemoryLayout<Float>.size] ? 1 : 0)
    }
    Issue.record("\(differing) samples differ, the first in \(span.name) at \(Double(sample / span.channels) / 48_000) s")
}

/// The seam of the golden mix is the whole mix, as the encoder gets it: every block, from the start of the timeline to
/// its end rounded to whole frames, mono or stereo as the tracks are, clipped and never past full scale, and silent
/// where nothing was recorded.
@Test func mixSamplesAreTheWholeMix() async throws {
    try await withTemporaryDirectory { dir in
        // A mono microphone: the 440 Hz sine at 1/4 of full scale over the 3 s.
        let phaseZero = try await GoldenProjects.make("phaseZero", in: dir)
        let mono = try await MP4Exporter.mixSamples(of: phaseZero)
        #expect(mono.count == 144_000)
        #expect(abs(toneAmplitude(mono, start: 0, frequency: 440, from: 0.5, to: 2.5) - 0.25) < 0.005)
        // At 30 fps the timeline rounds to the same 90 frames: the same samples.
        #expect(try await MP4Exporter.mixSamples(of: phaseZero, framesPerSecond: 30) == mono)

        // Paused from 1 to 2 s: silence there, the tone on both sides.
        let paused = try await MP4Exporter.mixSamples(of: try await GoldenProjects.make("pausedTake", in: dir))
        #expect(paused.count == 144_000)
        #expect(rms(paused, start: 0, from: 1.05, to: 1.95) == 0)
        for (from, to) in [(0.1, 0.9), (2.1, 2.9)] {
            #expect(abs(toneAmplitude(paused, start: 0, frequency: 440, from: from, to: to) - 0.25) < 0.005, "\(from) ..< \(to) s")
        }

        // The microphone at 0.6 and stereo system audio at 0.7: a stereo mix whose peaks are clipped to full scale.
        let stereo = try await MP4Exporter.mixSamples(of: try await GoldenProjects.make("twoAudioTracks", in: dir))
        #expect(stereo.count == 2 * 144_000)
        #expect(stereo.max() == 1 && stereo.min() == -1)

        // A frame rate that is not positive is refused, as the export refuses it.
        await #expect(throws: ExportError.self) { try await MP4Exporter.mixSamples(of: phaseZero, framesPerSecond: 0) }
    }
}
