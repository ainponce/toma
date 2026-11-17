// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

// An edited export's first or last clip that starts or ends inside the take (a trimmed start or end, the commonest
// edit) fades in or out over 192 frames (4 ms), as a cut does, so the MP4 never starts or ends on a step (final review
// C-M1). A clip at the take's own start or end does not: the legacy document mixes the samples it always did.

/// A take of the display and a microphone at a constant 0.25, 3 s long.
private func steadyTake(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: "edges")
    try await builder.addVideoTrack(
        id: displayID, source: displaySource,
        segments: [VideoSegmentSpec(start: base, seconds: 3, framesPerSecond: 10, width: 320, height: 180)])
    let steady: @Sendable (Int, CMSampleBuffer) -> CMSampleBuffer = { _, sample in
        guard let data = CMSampleBufferGetDataBuffer(sample) else { return sample }
        let values = [Float](repeating: 0.25, count: CMSampleBufferGetNumSamples(sample))
        let status = values.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: $0.count)
        }
        precondition(status == noErr, "steady block: \(status)")
        return sample
    }
    try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 3, transform: steady)])
    return try builder.write()
}

/// The whole mix of `project`'s legacy document with one clip over `[from, to)` seconds of the take, read off the pool.
private func mixed(_ project: LoadedProject, from: Double, to: Double) async throws -> [Float] {
    var document = EditDocument.legacy(for: project)
    document.sequence = [Clip(id: "c-00000001", take: project.take.id, start: base.adding(seconds: from), end: base.adding(seconds: to), speed: 1)]
    let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
    return try await withCheckedThrowingContinuation { continuation in
        Thread {
            var samples: [Float] = []
            mix.render(outputFrames: 0..<mix.totalFrames, into: &samples)
            continuation.resume(returning: samples)
        }.start()
    }
}

@Test func aTrimmedStartOrEndFadesLikeACut() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await steadyTake(in: dir)
        for (from, to) in [(0.5, 2.5), (0.5, 3.0), (0.0, 2.5), (0.0, 3.0)] {
            let samples = try await mixed(project, from: from, to: to)
            let count = Int((to - from) * 48_000)
            try #require(samples.count == count)
            var expected = [Float](repeating: 0.25, count: count)
            if from > 0 { for i in 0..<192 { expected[i] = 0.25 * (Float(i) / 192) } }
            if to < 3 { for j in 0..<192 { expected[count - 1 - j] = min(expected[count - 1 - j], 0.25 * (Float(j) / 192)) } }
            let worst = zip(samples, expected).map { abs($0 - $1) }.max() ?? 0
            #expect(worst < 1e-7, "[\(from), \(to)): \(worst) off the fades")
            #expect((samples[0] == 0) == (from > 0), "[\(from), \(to)): the first sample")
            #expect((samples[count - 1] == 0) == (to < 3), "[\(from), \(to)): the last sample")
        }
    }
}
