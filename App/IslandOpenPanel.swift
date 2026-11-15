// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Observation
import ProjectFormat
import Recording
import SwiftUI

/// A connected display as the panel lists it.
struct DisplayChoice: Identifiable {
    let info: DisplayInfo
    /// `NSScreen.localizedName`.
    let name: String
    var id: UInt32 { info.id }

    /// In pixels, "3024 × 1964".
    var resolution: String {
        let width = Int((info.frame.width * info.scale).rounded())
        let height = Int((info.frame.height * info.scale).rounded())
        return "\(width) × \(height)"
    }
}

/// What the open panel chooses: what to record and the quick settings. It starts from what was saved,
/// and Record saves it.
@MainActor @Observable
final class OpenPanelModel {
    var selection: CaptureSelection
    var quick: QuickSettings
    private(set) var displays: [DisplayChoice]
    /// The settings card over the columns.
    var showsSettings = false
    /// How long the countdown before a take lasts, as the settings window shows it too.
    let countdown: CountdownSetting
    /// What a stop does once the take is saved, as the settings window shows it too.
    let afterStop: AfterStopSetting
    /// Whether the teleprompter shows, as its switch in the open recording island shows it too.
    let teleprompter: TeleprompterSetting
    /// The chosen microphone's level, while the panel shows it.
    let levelPreview = MicrophoneLevelPreview()

    /// The pointer is over the row of this display (`nil`: over none).
    @ObservationIgnored var highlight: (UInt32?) -> Void = { _ in }
    @ObservationIgnored private let recording: RecordingController
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let microphoneList: MicrophoneList

    /// The saved selection if its displays are still connected; otherwise the display the island is on.
    init(
        recording: RecordingController, store: SettingsStore, countdown: CountdownSetting, afterStop: AfterStopSetting,
        teleprompter: TeleprompterSetting, microphones: MicrophoneList, displays: [DisplayChoice], islandDisplayID: UInt32
    ) {
        self.recording = recording
        self.store = store
        self.countdown = countdown
        self.afterStop = afterStop
        self.teleprompter = teleprompter
        microphoneList = microphones
        self.displays = displays
        let saved = store.settings
        quick = saved.quick
        let connected = Set(displays.map(\.id))
        if let selection = saved.selection, !selection.displayIDs.isEmpty, selection.displayIDs.allSatisfy(connected.contains) {
            self.selection = selection
        } else {
            selection = .mainDisplay(islandDisplayID)
        }
    }

    /// Displays were connected or disconnected.
    func update(displays: [DisplayChoice]) {
        self.displays = displays
    }

    /// The connected microphones, kept up to date by `MicrophoneList`.
    var microphones: [Microphone] { microphoneList.devices }

    /// Why Record is disabled, if it is: what keeps the selection from being recorded, or a take already
    /// in progress.
    var recordProblem: (any Error)? {
        if let problem = TakePlanner.problem(with: selection, displays: displays.map(\.info)) { return problem }
        return recording.isRecording ? RecordingError.alreadyStarted : nil
    }

    /// The display whose frame rate the settings show: the first one chosen.
    var chosenDisplay: DisplayChoice? {
        selection.displayIDs.first.flatMap { id in displays.first { $0.id == id } }
    }

    func choose(display id: UInt32) {
        selection.displayIDs = [id]
    }

    /// 30, and 60 when the display reaches it.
    func framesPerSecondOptions(for display: DisplayChoice) -> [Int] {
        display.info.maximumFramesPerSecond >= 60 ? [30, 60] : [30]
    }

    /// The frame rate the display records at, among the ones it offers.
    func framesPerSecond(for display: DisplayChoice) -> Int {
        let chosen = quick.framesPerSecond(display: display.id)
        let options = framesPerSecondOptions(for: display)
        return options.contains(chosen) ? chosen : options[0]
    }

    func setFramesPerSecond(_ value: Int, for display: DisplayChoice) {
        quick.framesPerSecondByDisplay[display.id] = value
    }

    /// Saves the selection and the settings and starts the take, at the frame rates the settings show. The
    /// take's phase takes the island to the countdown (or the wings).
    func record() {
        guard recordProblem == nil else { return }
        var quick = quick
        for display in displays where selection.displayIDs.contains(display.id) {
            quick.framesPerSecondByDisplay[display.id] = framesPerSecond(for: display)
        }
        var settings = store.settings
        settings.selection = selection
        settings.quick = quick
        store.settings = settings
        recording.startRecording(selection: selection, settings: quick)
    }
}

/// The open island (700 × 400, notch design §5.2): the mode, what to record (with the desktops, for a
/// display), the camera, audio and the teleprompter's switch, the settings and Record, and above Record why
/// a jump to another desktop posted nothing and why the last take could not start. Window, Area and what
/// this version does not record yet are drawn, disabled.
struct IslandOpenPanel: View {
    @Bindable var panel: OpenPanelModel
    let desktops: DesktopsModel
    /// Under the notch, the black band at the top.
    let topInset: Double
    /// Why the last take could not start (`userFacingDescription(of:)`), while the island says so.
    let startFailure: String?
    let send: (IslandEvent) -> Void

    /// Room for the columns: 700 wide, less the margins and the gaps, in the prototype's proportions.
    private static let columnWidths: (Double, Double, Double) = (221, 211.5, 211.5)

    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            header
            HStack(alignment: .top, spacing: 10) {
                Column(width: Self.columnWidths.0) { whatToRecord }
                Column(width: Self.columnWidths.1) { camera }
                Column(width: Self.columnWidths.2) { audioAndScript }
            }
            .frame(maxHeight: .infinity)
            // Over the columns only: ✕ above and Settings and Record below take one click with the card open.
            .overlay(alignment: .bottomLeading) { settingsCard }
            if let problem = desktops.problem {
                DesktopsProblemRow(model: desktops, problem: problem)
                    .transition(.opacity)
            }
            if let startFailure { StartFailureRow(description: startFailure) }
            footer
        }
        .padding(.top, topInset + 12)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
        .font(.system(size: 13))
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: panel.showsSettings)
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: desktops.problem)
    }

    /// The settings card, just above the Settings button; a click on the columns around it closes it, and
    /// so does Esc (`IslandPanel`).
    @ViewBuilder
    private var settingsCard: some View {
        if panel.showsSettings {
            ZStack(alignment: .bottomLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { panel.showsSettings = false }
                SettingsCard(panel: panel)
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
        }
    }

    // MARK: - Header

    private enum ModeTab: Hashable {
        case display, window, area, iPhone
    }

    private var header: some View {
        HStack {
            GlassSegmented(
                items: [
                    .init(value: ModeTab.display, title: Text("Display", comment: "What to record: a whole display"), icon: "display"),
                    .init(value: .window, title: Text("Window", comment: "What to record: one window"), icon: "macwindow"),
                    .init(value: .area, title: Text("Area", comment: "What to record: a rectangle of a display"), icon: "viewfinder"),
                    .init(value: .iPhone, title: Text(verbatim: "iPhone"), icon: "iphone", disabledHelp: String(localized: "Coming in phase 2.")),
                ],
                selection: Binding(
                    get: {
                        switch panel.selection.mode {
                        case .display: ModeTab.display
                        case .window: .window
                        case .area: .area
                        }
                    },
                    set: { tab in
                        switch tab {
                        case .display: panel.selection.mode = .display
                        case .window: panel.selection.mode = .window
                        case .area: panel.selection.mode = .area
                        case .iPhone: break  // disabled
                        }
                    }))
            Spacer()
            Button { send(.dismiss) } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(GlassButtonStyle(shape: .circle))
        }
    }

    // MARK: - What to record

    @ViewBuilder
    private var whatToRecord: some View {
        ColumnTitle(text: Text("What to Record"), icon: modeIcon)
        switch panel.selection.mode {
        case .display: displayColumn
        case .window: windowColumn
        case .area: areaColumn
        }
    }

    private var modeIcon: String {
        switch panel.selection.mode {
        case .display: "display"
        case .window: "macwindow"
        case .area: "viewfinder"
        }
    }

    @ViewBuilder
    private var displayColumn: some View {
        VStack(spacing: 2) {
            ForEach(panel.displays) { display in
                DisplayRow(
                    display: display, isChosen: panel.selection.displayIDs.contains(display.id),
                    choose: { panel.choose(display: display.id) },
                    hovering: { panel.highlight($0 ? display.id : nil) })
            }
        }
        Toggle(isOn: Binding(
            get: { panel.selection.displayIDs.count > 1 },
            set: { several in
                panel.selection.displayIDs = several ? panel.displays.map(\.id) : Array(panel.selection.displayIDs.prefix(1))
            }
        )) {
            Text("Record several displays").font(.system(size: 12))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .upcoming(.severalDisplays)
        Button { send(.beganChoosing) } label: {
            Label("Choose on Screen", systemImage: "display")
        }
        .buttonStyle(GlassButtonStyle())
        VStack(alignment: .leading, spacing: 6) {
            ColumnSubtitle(
                text: Text("Desktop", comment: "A display's only desktop (Space), and the open island's section of desktops"),
                icon: "rectangle.3.group")
            DesktopsList(model: desktops, layout: .column)
        }
        Spacer(minLength: 0)
    }

    /// Task 15 enables them: choosing sets `windowID` (and the area `area`).
    @ViewBuilder
    private var windowColumn: some View {
        Button {} label: { Label("Choose on Screen", systemImage: "macwindow") }
            .buttonStyle(GlassButtonStyle())
            .upcoming(.windowChoice)
        Button {} label: { Label("From Other Desktops", systemImage: "rectangle.3.group") }
            .buttonStyle(GlassButtonStyle(compact: true))
            .upcoming(.otherDesktopWindows)
        Spacer(minLength: 0)
    }

    @ViewBuilder
    private var areaColumn: some View {
        Button {} label: { Label("Draw on Screen", systemImage: "viewfinder") }
            .buttonStyle(GlassButtonStyle())
            .upcoming(.areaChoice)
        Button {} label: { Label("Saved Areas", systemImage: "bookmark") }
            .buttonStyle(GlassButtonStyle(compact: true))
            .upcoming(.areaChoice)
        Spacer(minLength: 0)
    }

    // MARK: - Camera

    @ViewBuilder
    private var camera: some View {
        HStack {
            ColumnTitle(text: Text("Camera"), icon: "video.fill")
            Spacer()
            Toggle(isOn: Binding(
                get: { panel.selection.camera != .off },
                set: { panel.selection.camera = $0 ? .systemDefault : .off }
            )) { Text("Camera") }
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
            .upcoming(.camera)
        }
        // Task 16e: the device, shape, size and where the bubble goes.
        Spacer(minLength: 0)
    }

    // MARK: - Audio and script

    private enum MicrophoneTag: Hashable {
        case systemDefault, off
        case device(String)
    }

    private enum SystemAudioTab: Hashable {
        case none, all, byApp
    }

    @ViewBuilder
    private var audioAndScript: some View {
        ColumnTitle(text: Text("Audio and Script"), icon: "mic.fill")
        ColumnSubtitle(text: Text("Microphone"))
        Picker(selection: microphone) {
            Text("System Default").tag(MicrophoneTag.systemDefault)
            ForEach(microphoneRows) { row in
                Text(verbatim: row.name).tag(MicrophoneTag.device(row.id))
            }
            Divider()
            Text("Off", comment: "Microphone: none").tag(MicrophoneTag.off)
        } label: {
            Text("Microphone")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        MicrophoneLevelRow(preview: panel.levelPreview, choice: panel.selection.microphone)
        ColumnSubtitle(text: Text("System Audio"), icon: "speaker.wave.2.fill")
        GlassSegmented(
            items: [
                .init(value: SystemAudioTab.none, title: Text("None", comment: "System audio: record none; the countdown: none")),
                .init(value: .all, title: Text("All", comment: "System audio: record all of it")),
                .init(value: .byApp, title: Text("By App")),
            ],
            selection: Binding(
                get: {
                    switch panel.selection.systemAudio {
                    case .off: SystemAudioTab.none
                    case .all: .all
                    case .applications: .byApp
                    }
                },
                set: { tab in
                    switch tab {
                    case .none: panel.selection.systemAudio = .off
                    case .all: panel.selection.systemAudio = .all
                    case .byApp: panel.selection.systemAudio = .applications([])
                    }
                }),
            compact: true)
        .upcoming(.systemAudio)
        HStack {
            ColumnSubtitle(text: Text("Teleprompter"), icon: "text.alignleft")
            Spacer()
            Toggle(isOn: panel.teleprompter.isOn) { Text("Teleprompter") }
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
        }
        Spacer(minLength: 0)
    }

    /// The connected microphones, and the chosen one if it is not connected now (by its ID).
    private var microphoneRows: [Microphone] {
        var rows = panel.microphones
        if case .device(let id) = panel.selection.microphone, !rows.contains(where: { $0.id == id }) {
            rows.append(Microphone(id: id, name: id))
        }
        return rows
    }

    private var microphone: Binding<MicrophoneTag> {
        Binding(
            get: {
                switch panel.selection.microphone {
                case .systemDefault: .systemDefault
                case .off: .off
                case .device(let id): .device(id)
                }
            },
            set: { tag in
                switch tag {
                case .systemDefault: panel.selection.microphone = .systemDefault
                case .off: panel.selection.microphone = .off
                case .device(let id): panel.selection.microphone = .device(uniqueID: id)
                }
            })
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button { panel.showsSettings.toggle() } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(GlassButtonStyle(isOn: panel.showsSettings))
            Spacer()
            let problem = panel.recordProblem
            // The reason is on a container: a disabled button shows no help.
            HStack {
                Button { panel.record() } label: {
                    Label {
                        Text("Record", comment: "The button that starts a recording")
                    } icon: {
                        Image(systemName: "record.circle")
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(RecordButtonStyle())
                .disabled(problem != nil)
            }
            .contentShape(Rectangle())
            .help(problem.map(userFacingDescription(of:)) ?? "")
        }
    }
}

/// The settings card: the chosen display's frame rate and resolution, and what is coming.
private struct SettingsCard: View {
    @Bindable var panel: OpenPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let display = panel.chosenDisplay {
                Text(verbatim: display.name).font(.system(size: 12, weight: .medium)).opacity(0.75)
                HStack(spacing: 8) {
                    GlassSegmented(
                        items: panel.framesPerSecondOptions(for: display).map { .init(value: $0, title: Text(verbatim: "\($0) fps")) },
                        selection: Binding(
                            get: { panel.framesPerSecond(for: display) },
                            set: { panel.setFramesPerSecond($0, for: display) }),
                        compact: true)
                    GlassSegmented(
                        items: [
                            .init(value: CaptureScale.native, title: Text("Native", comment: "Display resolution: the display's own pixels")),
                            .init(value: CaptureScale.points, title: Text("Points", comment: "Display resolution: one pixel per point")),
                        ],
                        selection: $panel.quick.displayScale,
                        compact: true)
                }
            }
            Divider().overlay(Color.white.opacity(0.12))
            HStack(spacing: 8) {
                Text("Countdown").opacity(0.75)
                Spacer(minLength: 0)
                GlassSegmented(
                    items: RecorderSettings.countdownOptions.map { .init(value: $0, title: CountdownSetting.label(for: $0)) },
                    selection: Binding(get: { panel.countdown.seconds }, set: { panel.countdown.set($0) }),
                    compact: true)
            }
            HStack(spacing: 8) {
                Text("When Recording Stops").opacity(0.75)
                Spacer(minLength: 0)
                // A menu, as the microphone's: it opens without activating the app.
                Picker(selection: Binding(get: { panel.afterStop.value }, set: { panel.afterStop.set($0) })) {
                    ForEach(AfterStop.allCases, id: \.self) { value in
                        AfterStopSetting.label(for: value).tag(value)
                    }
                } label: {
                    Text("When Recording Stops")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Divider().overlay(Color.white.opacity(0.12))
            SettingsToggle(title: Text("Do Not Disturb"), icon: "moon.fill").upcoming(.doNotDisturb)
            SettingsToggle(title: Text("Hide Desktop Icons"), icon: "eye.slash").upcoming(.hideDesktopIcons)
        }
        .font(.system(size: 12.5))
        .padding(12)
        .frame(width: 310, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(white: 0.1).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.16)))
        }
        // Clicks on the card stay on it.
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

/// Why the last take could not start, above Record: "Couldn't start recording" and the reason. A take
/// never shows an alert, which would activate the app.
private struct StartFailureRow: View {
    let description: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: NoticePresentation.stopped.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(NoticePresentation.stopped.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't start recording")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(verbatim: description)
                    .font(.system(size: 12))
                    .opacity(0.75)
                    .lineLimit(2)
            }
            .frame(maxWidth: 440, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The chosen microphone's live level (plan decision 31), heard while the panel shows it: nothing without
/// microphone access (asked for when Record is clicked) or with the microphone off.
private struct MicrophoneLevelRow: View {
    let preview: MicrophoneLevelPreview
    let choice: DeviceChoice

    var body: some View {
        // Always there, so it appears and disappears with the panel whether or not it shows the meter.
        Color.clear
            .frame(height: 12)
            .overlay(alignment: .leading) {
                if preview.isListening {
                    LevelMeter(peak: { preview.peakDecibels }, bars: 6, height: 12)
                }
            }
            .onAppear { preview.listen(to: choice) }
            .onChange(of: choice) { preview.listen(to: choice) }
            .onDisappear { preview.listen(to: nil) }
    }
}

/// A switch with an icon and a title, for what is not in this version yet (no field to bind to).
private struct SettingsToggle: View {
    let title: Text
    let icon: String

    var body: some View {
        Toggle(isOn: .constant(false)) {
            Label { title } icon: { Image(systemName: icon).symbolRenderingMode(.hierarchical) }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

// MARK: - Rows and columns

private struct Column<Content: View>: View {
    let width: Double
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(width: width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.10)))
            }
    }
}

private struct ColumnTitle: View {
    let text: Text
    var icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).symbolRenderingMode(.hierarchical) }
            text.textCase(.uppercase).tracking(0.9)
        }
        .font(.system(size: 11, weight: .semibold))
        .opacity(0.62)
    }
}

private struct ColumnSubtitle: View {
    let text: Text
    var icon: String?

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).symbolRenderingMode(.hierarchical) }
            text
        }
        .font(.system(size: 11))
        .opacity(0.62)
    }
}

private struct DisplayRow: View {
    let display: DisplayChoice
    let isChosen: Bool
    let choose: () -> Void
    let hovering: (Bool) -> Void
    @State private var isHovered = false
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: display.name).font(.system(size: 12.5)).lineLimit(1)
                Text(verbatim: display.resolution).font(.system(size: 11)).opacity(0.6)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color(nsColor: .systemBlue)))
                // It grows in; with "Reduce motion" it fades in.
                .scaleEffect(reduceMotion || isChosen ? 1 : 0.001)
                .opacity(reduceMotion && !isChosen ? 0 : 1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isChosen ? Color(nsColor: .systemBlue).opacity(0.30) : Color.white.opacity(isHovered ? 0.08 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { inside in
            isHovered = inside
            hovering(inside)
        }
        .onDisappear {
            if isHovered { hovering(false) }
        }
        .animation(.island(Motion.selector, reduceMotion: reduceMotion), value: isChosen)
    }
}

// MARK: - Coming later

/// What the island draws but this version does not do yet (decision 21). Each later task deletes its
/// cases: 16e `camera`; 15 the five of the selection and `systemAudio`; 17a `doNotDisturb`; 17b
/// `hideDesktopIcons` and the type.
enum UpcomingControl: CaseIterable {
    case windowChoice, otherDesktopWindows, areaChoice, severalDisplays, camera, systemAudio, doNotDisturb, hideDesktopIcons
}

extension View {
    /// Drawn, bound to its field, disabled, with "Coming in this version." as its help.
    func upcoming(_ control: UpcomingControl) -> some View {
        disabledWithHelp(String(localized: "Coming in this version."))
    }

    /// Disabled inside, with `help` on a container outside: a disabled control shows no help.
    func disabledWithHelp(_ help: String) -> some View {
        HStack(spacing: 0) { disabled(true) }
            .contentShape(Rectangle())
            .help(help)
    }
}
