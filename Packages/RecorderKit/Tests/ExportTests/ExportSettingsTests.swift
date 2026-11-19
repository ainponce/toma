// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
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

// The codecs of the export sheet (phase 2 design §6.8, plan 2b decision 13): HEVC at 0.6 × H.264's bitrate, ProRes without
// one, and the size each takes.

@Test func bitratesAndEstimates() {
    func settings(_ codec: ExportCodec, _ quality: ExportQuality = .standard) -> ExportSettings {
        ExportSettings(aspect: .landscape, resolution: .p1080, framesPerSecond: 60, quality: quality, codec: codec)
    }
    // H.264 as before: the formula's bitrate, and its estimate (9 953 280 + 160 000) b/s × 10 s / 8.
    #expect(settings(.h264).videoBitRate == 9_953_280 && settings(.h264).averageBitRate == 9_953_280)
    #expect(settings(.h264).estimatedBytes(durationSeconds: 10) == 12_641_600)
    #expect(settings(.h264, .high).videoBitRate == 17_418_240)
    // HEVC: 0.6 × H.264's at the same quality, rounded, with the same AAC.
    #expect(settings(.hevc).videoBitRate == 5_971_968)
    #expect(settings(.hevc, .high).videoBitRate == 10_450_944)
    #expect(settings(.hevc).estimatedBytes(durationSeconds: 10) == (5_971_968 + 160_000) * 10 / 8)
    #expect(ExportSettings(outputSize: [1280, 720], framesPerSecond: 30, codec: .hevc).videoBitRate == 1_327_104)  // 0.6 × 2 211 840
    // ProRes: no bitrate; 1920 × 1080 × 60 × 2.37 (422) or 3.54 (422 HQ) bits, plus 24-bit stereo LPCM at 48 kHz
    // (2 304 000 b/s), over 10 s.
    #expect(settings(.proRes422).videoBitRate == nil && settings(.proRes422HQ).videoBitRate == nil)
    #expect(settings(.proRes422).estimatedBytes(durationSeconds: 10) == 371_462_400)
    #expect(settings(.proRes422HQ).estimatedBytes(durationSeconds: 10) == 553_420_800)
    // ProRes has no quality to choose: High is the same file.
    #expect(settings(.proRes422, .high).estimatedBytes(durationSeconds: 10) == 371_462_400)
    #expect(settings(.proRes422HQ, .high).estimatedBytes(durationSeconds: 10) == 553_420_800)
    for codec in ExportCodec.allCases {
        #expect(settings(codec).estimatedBytes(durationSeconds: 0) == 0, "\(codec)")
    }
}

@Test func codecsAndTheirFiles() {
    #expect(ExportCodec.allCases == [.h264, .hevc, .proRes422, .proRes422HQ])
    #expect(ExportCodec.allCases.map(\.rawValue) == ["h264", "hevc", "proRes422", "proRes422HQ"])
    #expect(ExportCodec.allCases.map(\.fileExtension) == ["mp4", "mp4", "mov", "mov"])
    #expect(ExportCodec.allCases.map(\.fileType) == [.mp4, .mp4, .mov, .mov])
    // H.264 unless asked otherwise, by either initializer; the codec changes neither the size nor the rate.
    #expect(ExportSettings().codec == .h264)
    #expect(ExportSettings(aspect: .square, resolution: .p720, framesPerSecond: 30, quality: .high).codec == .h264)
    let proRes = ExportSettings(aspect: .square, resolution: .p720, framesPerSecond: 30, quality: .high, codec: .proRes422HQ)
    #expect(proRes.codec == .proRes422HQ && proRes.outputSize == [720, 720] && proRes.framesPerSecond == 30)
    #expect(ExportSettings(outputSize: [640, 360], framesPerSecond: 24, codec: .hevc).codec == .hevc)
    #expect(ExportSettings(codec: .hevc) != ExportSettings())
}
