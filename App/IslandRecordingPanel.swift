// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import SwiftUI

/// While a take records: the wings at each side of the notch, each `IslandGeometry.wingWidth` wide, or
/// the pill on a screen without one. On the left the recording dot and the time recorded; on the right
/// a warning icon while a notice asks for attention (amber; red once the take stopped by itself or closed
/// with an error), and the microphone's level, nothing more while it hears nothing ("No Signal" in the
/// pill, which has room for it; the open island always says it), or a crossed-out microphone when the
/// take has none.
struct RecordingWings: View {
    let recording: RecordingController
    /// The notch's width, which the wings leave free; `nil` on a pill.
    let notchWidth: Double?
    /// The warning icon's (`IslandMachine.attention`).
    let attention: NoticePresentation?

    var body: some View {
        Group {
            if let notchWidth {
                HStack(spacing: 0) {
                    time
                        .padding(.horizontal, 10)
                        .frame(width: IslandGeometry.wingWidth, alignment: .leading)
                    Color.clear.frame(width: notchWidth)
                    MicrophoneStatus(recording: recording, attention: attention, namesSilence: false)
                        .padding(.horizontal, 10)
                        .frame(width: IslandGeometry.wingWidth, alignment: .trailing)
                }
            } else {
                HStack(spacing: 0) {
                    time
                    Spacer(minLength: 0)
                    MicrophoneStatus(recording: recording, attention: attention)
                }
                .padding(.horizontal, 16)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .lineLimit(1)
    }

    private var time: some View {
        HStack(spacing: 6) {
            RecordingDot(isPaused: recording.isUserPaused || recording.isPaused)
            // 53 pt at mm:ss and 62 pt at h:mm:ss of the 64 the wing has inside; ten hours and more shrink a little.
            RecordedTimeText(recording: recording, size: 13, hoursSize: 12, weight: .semibold)
                .minimumScaleFactor(0.85)
        }
    }
}

/// The open island while a take records (640 × 226, notch design §5.1): the time, large, whether it is
/// recording or paused and the microphone's level; pause or resume, marker, restart (asking first) and
/// stop, the desktops by name (or ← →) and Mission Control (§5.5), and the teleprompter's switch; below
/// them, why a jump to another desktop posted nothing, and the take's notices that ask for attention,
/// until they are resolved.
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
                if let problem = model.desktops.problem {
                    DesktopsProblemRow(model: model.desktops, problem: problem)
                        .transition(.opacity)
                }
            }
            // The confirmations were capsules: what is listed is what still asks for attention.
            let notices = recording.notices.filter { $0.presentation != .confirmation }
            if notices.isEmpty {
                Spacer(minLength: 0)
            } else {
                IslandNoticeList(notices: notices, closeError: recording.lastCloseError)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.top, topInset + 12)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: model.isConfirmingRestart)
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: model.desktops.problem)
        .onDisappear {
            if model.isConfirmingRestart { confirm(false) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RecordingDot(isPaused: isPaused)
            RecordedTimeText(recording: recording, size: 28, hoursSize: 28, weight: .bold)
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
            ControlSeparator()
            DesktopsList(model: model.desktops, layout: .row)
            RoundControl(symbol: "rectangle.3.group", title: String(localized: "Mission Control")) {
                model.desktops.openMissionControl()
            }
            ControlSeparator()
            let teleprompter = model.teleprompter
            RoundControl(symbol: "text.alignleft", title: String(localized: "Teleprompter"), isOn: teleprompter.value.isOn) {
                teleprompter.update { $0.isOn.toggle() }
            }
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

/// A round glass button with a symbol, its title as help and for VoiceOver; lit while `isOn`, for a switch.
struct RoundControl: View {
    let symbol: String
    let title: String
    var isStop = false
    var isEnabled = true
    var isOn = false
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
            .buttonStyle(isStop ? AnyButtonStyle(StopButtonStyle()) : AnyButtonStyle(GlassButtonStyle(shape: .circle, isOn: isOn)))
            .disabled(!isEnabled)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
        .contentShape(Circle())
        .help(title)
    }
}

/// Between groups of round controls.
private struct ControlSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
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
    /// The ring is drawn again 30 times a second at most, not on every frame of the display (120 on ProMotion): the
    /// wings are on the main thread for the whole take.
    private static let ringInterval = 1.0 / 30

    var body: some View {
        Circle()
            .fill(isPaused ? Self.amber : Self.red)
            .frame(width: size, height: size)
            .background {
                if !isPaused, !reduceMotion {
                    TimelineView(.animation(minimumInterval: Self.ringInterval)) { context in
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

/// The time the take has recorded, without its pauses, with tabular digits: "4:12" and "12:34" at `size`,
/// "1:02:03" at `hoursSize` from the first hour on.
struct RecordedTimeText: View {
    let recording: RecordingController
    let size: Double
    let hoursSize: Double
    let weight: Font.Weight

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let elapsed = recording.elapsed(at: context.date)
            Text(verbatim: elapsed.recordedTime)
                .font(.system(size: elapsed >= .seconds(3600) ? hoursSize : size, weight: weight))
                .monospacedDigit()
        }
    }
}

extension Duration {
    /// A take's time as the island and the menu bar show it: m:ss, then h:mm:ss from the first hour on.
    var recordedTime: String {
        self >= .seconds(3600) ? formatted(.time(pattern: .hourMinuteSecond)) : formatted(.time(pattern: .minuteSecond))
    }
}

/// The right wing: a warning icon while `attention` is set, then the microphone's level; while it hears
/// nothing, an amber warning (whatever `attention` is) and "No Signal" if `namesSilence`; a crossed-out
/// microphone when the take records none.
private struct MicrophoneStatus: View {
    let recording: RecordingController
    /// The wing's warning (`IslandMachine.attention`); `nil` in the open island, which lists the notices.
    var attention: NoticePresentation?
    var bars = 5
    var namesSilence = true

    var body: some View {
        let silent = recording.recordsMicrophone && recording.notices.contains(.microphoneSilent)
        HStack(spacing: 5) {
            if let warning = attention ?? (silent ? .attention : nil) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(warning.tint)
                    .accessibilityLabel(warningLabel(silent: silent, warning: warning))
            }
            if !recording.recordsMicrophone {
                Image(systemName: "mic.slash")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.hierarchical)
                    .opacity(0.55)
            } else if silent {
                if namesSilence { Text("No Signal").foregroundStyle(NoticePresentation.attention.tint) }
            } else {
                let paused = recording.isUserPaused || recording.isPaused
                // Paused, nothing is recorded: the meter rests.
                LevelMeter(peak: { paused ? AudioPeak.silence : recording.microphoneLevel }, bars: bars)
            }
        }
    }

    /// What the icon warns about: the silence, or the last notice of its color.
    private func warningLabel(silent: Bool, warning: NoticePresentation) -> Text {
        if silent, warning == .attention { return Text("No Signal") }
        let notice = recording.notices.last { $0.presentation == warning }
        return Text(verbatim: notice?.text(closeError: recording.lastCloseError) ?? "")
    }
}
