// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreMedia
import Dispatch
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import SyntheticCapture
import Testing

/// The microphone's level: its peak, the silence warning and the meter's motion.
@Suite struct LevelMeterTests {
    @Test func silenceWatchWarnsAfterFiveSilentSeconds() {
        var watch = SilenceWatch()
        #expect(watch.observe(peakDecibels: -90, recordedSeconds: 1) == .listening)
        #expect(watch.observe(peakDecibels: -90, recordedSeconds: 2) == .listening)
        #expect(watch.observe(peakDecibels: -90, recordedSeconds: 3) == .listening)
        #expect(watch.observe(peakDecibels: -90, recordedSeconds: 4) == .listening)
        #expect(watch.observe(peakDecibels: -90, recordedSeconds: 5) == .silent)
        // Once.
        #expect(watch.observe(peakDecibels: -90, recordedSeconds: 6) == .listening)
        #expect(watch.observe(peakDecibels: -20, recordedSeconds: 7) == .heard)
        #expect(watch.observe(peakDecibels: -90, recordedSeconds: 8) == .heard)

        // A sound before the five seconds: never a warning. The threshold itself is not a sound.
        var heard = SilenceWatch()
        #expect(heard.observe(peakDecibels: SilenceWatch.thresholdDecibels, recordedSeconds: 1) == .listening)
        #expect(heard.observe(peakDecibels: -69, recordedSeconds: 2) == .heard)
        #expect(heard.observe(peakDecibels: -160, recordedSeconds: 9) == .heard)
        #expect(SilenceWatch.window == 5 && SilenceWatch.thresholdDecibels == -70)
    }

    @Test func silenceWatchIgnoresPausedTime() {
        var watch = SilenceWatch()
        // Paused at 3 s recorded: the time recorded does not move, however long the pause lasts.
        for seconds in [1.0, 2, 3, 3, 3, 3, 3, 3, 3, 3, 4] {
            #expect(watch.observe(peakDecibels: -160, recordedSeconds: seconds) == .listening)
        }
        #expect(watch.observe(peakDecibels: -160, recordedSeconds: 5) == .silent)
    }

    @Test func meteredSourceReportsPeakOfLastBuffer() async throws {
        let audio = SyntheticAudioSource()
        let metered = MeteredSource(audio)
        #expect(metered.trackID == audio.trackID && metered.kind == .microphone && metered.media == .audio)
        #expect(metered.peakDecibels == -160)  // nothing heard yet
        let queue = DispatchSerialQueue(label: "LevelMeterTests")
        let sink = RecordingSink(queue: queue)
        try await metered.start(on: queue, sink: sink)
        #expect(metered.activeDeviceUniqueID == audio.activeDeviceUniqueID)

        // Read from another task while the source delivers on its queue.
        let reader = Task.detached {
            var readings: [Float] = []
            for _ in 0..<40 {
                readings.append(metered.peakDecibels)
                try? await Task.sleep(for: .milliseconds(5))
            }
            return readings
        }
        #expect(await eventually { sink.samples.count >= 20 })
        let readings = await reader.value
        // A 440 Hz sine at a quarter of full scale: 20 · log10(0.25).
        #expect(abs(metered.peakDecibels - -12.04) < 0.1)
        #expect(readings.allSatisfy { $0 == -160 || abs($0 - -12.04) < 0.1 })
        // Every block reaches the sink as it was.
        #expect(sink.samples.allSatisfy { $0.trackID == "mic" && $0.frames == 480 })

        // A silent microphone: the last block's peak.
        audio.amplitude = 0
        #expect(await eventually { metered.peakDecibels == -160 })
        audio.amplitude = 0.5
        #expect(await eventually { abs(metered.peakDecibels - -6.02) < 0.1 })

        // Stopped: nothing is heard any more.
        await metered.stop()
        #expect(metered.peakDecibels == -160)
    }

    @Test func audioPeakReadsTheLoudestSample() {
        let quarter = SampleFactory.audioSample(pts: HostTime(nanoseconds: 1_000_000_000), frames: 480, sampleRate: 48_000, channels: 2)
        #expect(abs(AudioPeak.decibels(of: quarter) - -12.04) < 0.1)
        let silent = SampleFactory.audioSample(
            pts: HostTime(nanoseconds: 1_000_000_000), frames: 480, sampleRate: 48_000, channels: 1, amplitude: 0)
        #expect(AudioPeak.decibels(of: silent) == -160)
        let full = SampleFactory.audioSample(
            pts: HostTime(nanoseconds: 1_000_000_000), frames: 480, sampleRate: 48_000, channels: 1, amplitude: 1)
        #expect(abs(AudioPeak.decibels(of: full)) < 0.1)
    }

    @Test func meterRisesFastAndFallsSlowly() {
        #expect(MeterBallistics.attack == 0.045 && MeterBallistics.release == 0.110 && MeterBallistics.floorDecibels == -60)
        var rising = MeterBallistics()
        #expect(rising.level == 0)
        #expect(abs(rising.update(peakDecibels: 0, seconds: 0.045) - 0.632) < 0.001)
        #expect(abs(rising.level - 0.632) < 0.001)

        var falling = MeterBallistics()
        _ = falling.update(peakDecibels: 0, seconds: 10)
        #expect(falling.level == 1)
        #expect(abs(falling.update(peakDecibels: -160, seconds: 0.110) - 0.368) < 0.001)

        // Halfway between the floor and full scale; nothing changes without time.
        var middle = MeterBallistics()
        _ = middle.update(peakDecibels: -30, seconds: 10)
        #expect(abs(middle.level - 0.5) < 0.000_001)
        #expect(middle.update(peakDecibels: 0, seconds: 0) == middle.level)
    }
}
