// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import SwiftUI

/// While a take records: the wings at each side of the notch (or in the pill), 320 × the menu bar's
/// height. On the left the recording dot and the time recorded; on the right the microphone's level, "No
/// Signal" while it hears nothing, or a crossed-out microphone when the take has none.
struct RecordingWings: View {
    let recording: RecordingController

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                RecordingDot(isPaused: recording.isUserPaused || recording.isPaused)
                RecordedTimeText(recording: recording)
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer(minLength: 0)
            MicrophoneStatus(recording: recording)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .lineLimit(1)
    }
}

/// The open island while a take records (640 × 226, notch design §5.1): the time, large, whether it is
/// recording or paused and the microphone's level; pause or resume, marker, restart (asking first) and
/// stop. Task 16d adds the desktops and Mission Control after the buttons, Task 16c the teleprompter
/// switch, and Task 16b the notices below them.
struct IslandRecordingPanel: View {
    let recording: RecordingController
    let model: IslandModel
    /// Under the notch, the black band at the top.
    let topInset: Double
    let send: (IslandEvent) -> Void

    @Environment(\.islandReduceMotion) private var reduceMotion

    private var isPaused: Bool { recording.isUserPaused || recording.isPaused }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.isConfirmingRestart {
                confirmation
                    .transition(.opacity)
            } else {
                controls
                    .transition(.opacity)
            }
            // Task 16b: the take's notices go here.
            Spacer(minLength: 0)
        }
        .padding(.top, topInset + 12)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: model.isConfirmingRestart)
        .onDisappear {
            if model.isConfirmingRestart { confirm(false) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RecordingDot(isPaused: isPaused)
            RecordedTimeText(recording: recording)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.56)
            Group {
                if isPaused {
                    Text("Paused", comment: "Menu item, and the open island, while the user has paused the take")
                } else {
                    // "Recording" alone is the start of a new project's name.
                    Text(String(
                        localized: "Recording (island state)", defaultValue: "Recording",
                        comment: "The open island while a take records: its state"))
                }
            }
            .font(.system(size: 12))
            .opacity(0.65)
            Spacer(minLength: 0)
            MicrophoneStatus(recording: recording, bars: 6)
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            let pauseTitle = isPaused ? String(localized: "Resume") : String(localized: "Pause")
            RoundControl(symbol: isPaused ? "play.fill" : "pause.fill", title: pauseTitle) { recording.togglePause() }
            // Nothing is written while paused.
            RoundControl(symbol: "flag.fill", title: String(localized: "Marker"), isEnabled: !isPaused) { recording.addMarker() }
            RoundControl(symbol: "arrow.counterclockwise", title: String(localized: "Restart")) { confirm(true) }
            RoundControl(symbol: "stop.fill", title: String(localized: "Stop"), isStop: true) { recording.stopRecording() }
            // Task 16d: a separator, the desktops by name and Mission Control go here; Task 16c: the
            // teleprompter switch.
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Restart the take? This one goes to the trash.")
                .font(.system(size: 12.5))
            HStack(spacing: 8) {
                Button {
                    confirm(false)
                    recording.restartTake()
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(RecordButtonStyle())
                Button { confirm(false) } label: { Text("Cancel") }
                    .buttonStyle(GlassButtonStyle())
            }
        }
    }

    /// Shows or hides the confirmation; the island stays open while it shows.
    private func confirm(_ shown: Bool) {
        guard model.isConfirmingRestart != shown else { return }
        model.isConfirmingRestart = shown
        send(.confirmationShown(shown))
    }
}

/// A round glass button with a symbol, its title as help and for VoiceOver.
private struct RoundControl: View {
    let symbol: String
    let title: String
    var isStop = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        // The help is on a container: a disabled button shows none.
        HStack(spacing: 0) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(isStop ? AnyButtonStyle(StopButtonStyle()) : AnyButtonStyle(GlassButtonStyle(shape: .circle)))
            .disabled(!isEnabled)
            .accessibilityLabel(Text(verbatim: title))
        }
        .contentShape(Circle())
        .help(title)
    }
}

/// Stop: red, like Record.
private struct StopButtonStyle: ButtonStyle {
    @Environment(\.islandReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 1, green: 0.35, blue: 0.31), Color(red: 0.9, green: 0.21, blue: 0.17)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().stroke(Color.white.opacity(0.3)))
            }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Either of two button styles, chosen at run time.
private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some ButtonStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// The recording dot: red, with a ring that grows and fades every 1.8 s; amber and still while paused
/// (by the user or the system), and without the ring with "Reduce motion".
struct RecordingDot: View {
    let isPaused: Bool
    var size = 9.0
    @Environment(\.islandReduceMotion) private var reduceMotion

    private static let red = Color(red: 1, green: 0.27, blue: 0.23)
    private static let amber = Color(red: 1, green: 0.7, blue: 0.25)
    private static let period = 1.8
    /// The ring is gone at 70 % of the period, as in the prototype.
    private static let spread = 0.7
    private static let ringWidth = 7.0

    var body: some View {
        Circle()
            .fill(isPaused ? Self.amber : Self.red)
            .frame(width: size, height: size)
            .background {
                if !isPaused, !reduceMotion {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                        let grown = min(phase / Self.spread, 1)
                        Circle()
                            .fill(Self.red.opacity(0.55 * (1 - grown)))
                            .frame(width: size + 2 * Self.ringWidth * grown, height: size + 2 * Self.ringWidth * grown)
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

/// The time the take has recorded, without its pauses: "04:12".
struct RecordedTimeText: View {
    let recording: RecordingController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            Text(verbatim: recording.elapsed(at: context.date).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2))))
                .monospacedDigit()
        }
    }
}

/// The right wing: the microphone's level; "No Signal" while it hears nothing; a crossed-out microphone
/// when the take records none.
private struct MicrophoneStatus: View {
    let recording: RecordingController
    var bars = 5

    var body: some View {
        if !recording.recordsMicrophone {
            Image(systemName: "mic.slash")
                .font(.system(size: 14))
                .symbolRenderingMode(.hierarchical)
                .opacity(0.55)
        } else if recording.notices.contains(.microphoneSilent) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.hierarchical)
                Text("No Signal")
            }
            .foregroundStyle(Color(red: 1, green: 0.7, blue: 0.25))
        } else {
            let paused = recording.isUserPaused || recording.isPaused
            // Paused, nothing is recorded: the meter rests.
            LevelMeter(peak: { paused ? AudioPeak.silence : recording.microphoneLevel }, bars: bars)
        }
    }
}
