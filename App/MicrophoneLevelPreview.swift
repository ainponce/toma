// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppSupport
import CoreMedia
import Dispatch
import Observation
import Recording
import SwiftUI
import os

/// The chosen microphone's level before a take, for the open panel's meter (plan decision 31): the
/// microphone is opened only while the panel shows it and only if access is already granted (it is
/// asked for when Record is clicked, never here). It is the take's own microphone source, metered.
@MainActor @Observable
final class MicrophoneLevelPreview {
    /// Listening to a microphone now: its source has started.
    private(set) var isListening = false

    @ObservationIgnored private var choice: DeviceChoice?
    @ObservationIgnored private var source: MeteredSource?
    /// Starts and stops the sources one after the other.
    @ObservationIgnored private var lastChange: Task<Void, Never>?
    @ObservationIgnored private let queue = DispatchSerialQueue(label: "dev.toma.Toma.MicrophoneLevelPreview")

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Recording")

    /// The peak of the last block heard, in dBFS; `AudioPeak.silence` while not listening. Not observed:
    /// read it as often as it is drawn.
    var peakDecibels: Float { source?.peakDecibels ?? AudioPeak.silence }

    /// Listens to `choice`, if access is granted and it is not `.off`; `nil` stops listening.
    func listen(to choice: DeviceChoice?) {
        let granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let wanted = choice.flatMap { $0 == .off || !granted ? nil : $0 }
        guard wanted != self.choice else { return }
        self.choice = wanted
        let previous = source
        let next = wanted.map { MeteredSource(LiveCaptureSourceFactory().microphone($0)) }
        source = next
        isListening = false
        let before = lastChange
        let queue = queue
        lastChange = Task { [weak self] in
            await before?.value
            await previous?.stop()
            guard let next else { return }
            do {
                try await next.start(on: queue, sink: DiscardingSink())
                // Unless another microphone, or none, was asked for meanwhile.
                if let self, source === next { isListening = true }
            } catch {
                Self.logger.notice("The microphone level can't be shown: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// Lets every block go: the preview only measures them.
private final class DiscardingSink: CaptureSink {
    func source(_ trackID: String, didOutput sample: CMSampleBuffer) {}
    func source(_ trackID: String, didStopWithError error: any Error) {}
}

/// A microphone's level as a few bars that rise fast and fall slowly (`MeterBallistics`, every frame), from
/// the peak `peak` reads at each frame; yellow near full scale.
struct LevelMeter: View {
    /// The peak now, in dBFS.
    let peak: () -> Float
    var bars = 5
    var height = 14.0
    @State private var motion = MeterMotion()

    /// Each bar's share of the level, so the bars do not move as one block.
    private static let weights = [0.78, 1.0, 0.9, 0.82, 0.95, 0.72]

    var body: some View {
        TimelineView(.animation) { context in
            let level = motion.level(peak: peak(), at: context.date)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<bars, id: \.self) { index in
                    let fill = min(max(level * Self.weights[index % Self.weights.count], 0.15), 1)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(fill > 0.92 ? Color(red: 1, green: 0.84, blue: 0.04) : Color(red: 0.2, green: 0.84, blue: 0.29))
                        .frame(width: 3, height: height * fill)
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// The meter's motion between frames. A reference, so moving it while drawing changes no SwiftUI state.
private final class MeterMotion {
    private var ballistics = MeterBallistics()
    private var last: Date?

    func level(peak: Float, at date: Date) -> Double {
        // At most a tenth of a second at once: after a pause in drawing the meter moves, it does not jump.
        let seconds = last.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        last = date
        return ballistics.update(peakDecibels: peak, seconds: seconds)
    }
}
