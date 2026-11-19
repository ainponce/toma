// SPDX-License-Identifier: GPL-3.0-or-later
import Export
import ProjectFormat
import Testing

// The export sheet's options (design §5.6): the project's aspect at a resolution, a frame rate and a quality, with the
// size the export will take.

@Test func outputSizesAndBitrates() {
    let standard = ExportSettings(aspect: .landscape, resolution: .p1080, framesPerSecond: 60, quality: .standard)
    #expect(standard.outputSize == [1920, 1080])
    #expect(standard.averageBitRate == 9_953_280)  // 1920 × 1080 × 60 × 0.08
    #expect(ExportSettings(aspect: .landscape, resolution: .p1080, framesPerSecond: 60, quality: .high).averageBitRate == 17_418_240)
    #expect(ExportSettings(aspect: .portrait, resolution: .p2160, framesPerSecond: 60, quality: .standard).outputSize == [2160, 3840])
    #expect(ExportQuality.standard.bitsPerPixel == 0.08 && ExportQuality.high.bitsPerPixel == 0.14)

    // Every aspect at every resolution: the short side is the resolution, both sides even.
    let sizes: [Aspect: [SIMD2<Int>]] = [
        .landscape: [[1280, 720], [1920, 1080], [2560, 1440], [3840, 2160]],
        .portrait: [[720, 1280], [1080, 1920], [1440, 2560], [2160, 3840]],
        .square: [[720, 720], [1080, 1080], [1440, 1440], [2160, 2160]],
    ]
    for (aspect, expected) in sizes {
        let made = ExportResolution.allCases.map {
            ExportSettings(aspect: aspect, resolution: $0, framesPerSecond: 30, quality: .standard).outputSize
        }
        #expect(made == expected, "\(aspect)")
    }
    #expect(ExportResolution.allCases.map(\.rawValue) == [720, 1080, 1440, 2160])

    // The settings of phase 0 and 1a keep their quality, and their bitrate.
    let today = ExportSettings(outputSize: [1280, 720], framesPerSecond: 30)
    #expect(today.quality == .standard && today.averageBitRate == 2_211_840)
}

@Test func estimateIncludesAudio() {
    let settings = ExportSettings(aspect: .landscape, resolution: .p1080, framesPerSecond: 60, quality: .standard)
    // (9 953 280 + 160 000) b/s × 60 s / 8.
    #expect(settings.estimatedBytes(durationSeconds: 60) == 75_849_600)
    #expect(settings.estimatedBytes(durationSeconds: 0) == 0)
    let high = ExportSettings(aspect: .square, resolution: .p720, framesPerSecond: 30, quality: .high)
    #expect(high.estimatedBytes(durationSeconds: 10) == Int64((720 * 720 * 30 * 0.14 + 160_000) * 10 / 8))
}

@Test func higherThanTheRecording() {
    // A 1512 × 982 display.
    #expect(ExportSettings.exceedsRecording(.p1080, recordedShortSide: 982))
    #expect(!ExportSettings.exceedsRecording(.p720, recordedShortSide: 982))
    #expect(ExportSettings.exceedsRecording(.p2160, recordedShortSide: 982))
    // As much as the recording is not more.
    #expect(!ExportSettings.exceedsRecording(.p1080, recordedShortSide: 1080))
    #expect(ExportSettings.exceedsRecording(.p1440, recordedShortSide: 1080))
}

@Test func exportSizesOfAuto() {
    let wide = ExportSettings(aspect: .auto, resolution: .p1080, framesPerSecond: 30, quality: .standard, contentRatio: 2.4)
    #expect(wide.outputSize == [2592, 1080])
    // Without a ratio, or one within 1 % of 16:9, it is 16:9; the fixed aspects ignore it.
    #expect(ExportSettings(aspect: .auto, resolution: .p1080, framesPerSecond: 30, quality: .standard).outputSize == [1920, 1080])
    #expect(ExportSettings(aspect: .auto, resolution: .p720, framesPerSecond: 30, quality: .standard, contentRatio: 1.78).outputSize == [1280, 720])
    #expect(ExportSettings(aspect: .fourByFive, resolution: .p1080, framesPerSecond: 30, quality: .standard, contentRatio: 2.4).outputSize == [1080, 1350])
}
