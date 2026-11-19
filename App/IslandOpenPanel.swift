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
    /// Whether the desktop's icons are hidden while recording, as the settings window shows it too.
    let hideDesktopIcons: HideDesktopIconsSetting
    /// The shortcut that turns Do Not Disturb on around each take, as the settings window shows it too.
    let focusShortcut: FocusShortcutSetting
    /// Whether the teleprompter shows, as its switch in the open recording island shows it too.
    let teleprompter: TeleprompterSetting
    /// The camera's look and permission, as the bubble shows them too.
    let camera: CameraSetting
    /// The chosen microphone's level, while the panel shows it.
    let levelPreview = MicrophoneLevelPreview()
    /// System audio's permission, asked for when system audio is turned on.
    let systemAudio: SystemAudioSetting
    /// The open apps, for system audio by app.
    let audioApplications: AudioApplicationList
    /// The window chosen in Window mode, as the window server told it when it was chosen.
    var chosenWindow: WindowCandidate?
    /// Window mode's windows of other desktops, by app; read each time the window column shows.
    var otherDesktopWindows: [AppWindows] = []
    /// The areas saved ("Save Area"), saved at once.
    private(set) var savedAreas: SavedAreas
    /// The proportion an area is drawn with, saved at once.
    private(set) var aspectLock: AspectLock
    /// The grid of thirds over the area being drawn.
    var showsGrid = true

    /// The pointer is over the row of this display (`nil`: over none).
    @ObservationIgnored var highlight: (UInt32?) -> Void = { _ in }
    /// The capsule under the island confirms what the user just did.
    @ObservationIgnored var confirm: (IslandConfirmation) -> Void = { _ in }
    /// The "Library" button: the island closes and the library opens.
    @ObservationIgnored var openLibrary: () -> Void = {}
    @ObservationIgnored private let recording: RecordingController
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let microphoneList: CaptureDeviceList
    @ObservationIgnored private let cameraList: CaptureDeviceList

    /// The saved selection, with what is no longer there left out: the displays that are not connected (the
    /// display the island is on when none is left), an area of a display that is not connected, a window that is
    /// closed or is no longer the one chosen (`WindowList.restored`; Window mode then has no window chosen). The
    /// camera is on only if it is allowed: what the panel shows is what is recorded.
    init(
        recording: RecordingController, store: SettingsStore, countdown: CountdownSetting, afterStop: AfterStopSetting,
        hideDesktopIcons: HideDesktopIconsSetting, focusShortcut: FocusShortcutSetting, teleprompter: TeleprompterSetting,
        camera: CameraSetting, systemAudio: SystemAudioSetting, audioApplications: AudioApplicationList,
        microphones: CaptureDeviceList, cameras: CaptureDeviceList, displays: [DisplayChoice], islandDisplayID: UInt32
    ) {
        self.recording = recording
        self.store = store
        self.countdown = countdown
        self.afterStop = afterStop
        self.hideDesktopIcons = hideDesktopIcons
        self.focusShortcut = focusShortcut
        self.teleprompter = teleprompter
        self.camera = camera
        self.systemAudio = systemAudio
        self.audioApplications = audioApplications
        microphoneList = microphones
        cameraList = cameras
        self.displays = displays
        let saved = store.settings
        quick = saved.quick
        savedAreas = saved.savedAreas
        aspectLock = saved.aspectLock
        let connected = Set(displays.map(\.id))
        var selection = saved.selection ?? .mainDisplay(islandDisplayID)
        selection.displayIDs = selection.displayIDs.filter(connected.contains)
        if selection.displayIDs.isEmpty { selection.displayIDs = [islandDisplayID] }
        if let area = selection.area, !connected.contains(area.displayID) { selection.area = nil }
        let window = WindowList.restored(selection)
        if window == nil {
            selection.windowID = nil
            selection.windowOwner = nil
        }
        chosenWindow = window
        self.selection = selection
        camera.refreshPermission()
        if camera.permission != .granted { self.selection.camera = .off }
        systemAudio.refreshPermission()
    }

    /// Displays were connected or disconnected.
    func update(displays: [DisplayChoice]) {
        self.displays = displays
    }

    /// The connected microphones and cameras, kept up to date by their `CaptureDeviceList`.
    var microphones: [CaptureDevice] { microphoneList.devices }
    var cameras: [CaptureDevice] { cameraList.devices }

    var isCameraOn: Bool { selection.camera != .off }

    /// Off at once. On, if the camera is allowed; the first time, once the system's prompt says it is (the
    /// island makes room for the prompt meanwhile). Once it was refused, the camera column says so and offers
    /// System Settings instead.
    func setCamera(on: Bool) {
        guard on else {
            selection.camera = .off
            return
        }
        switch PermissionAction(for: camera.permission) {
        case nil:
            if selection.camera == .off { selection.camera = .systemDefault }
        case .prompt:
            Task {
                guard await camera.requestAccess(), selection.camera == .off else { return }
                selection.camera = .systemDefault
            }
        case .openSettings:
            break
        }
    }

    /// Why Record is disabled, if it is: what keeps the selection from being recorded, or a take already
    /// in progress.
    var recordProblem: (any Error)? {
        if let problem = TakePlanner.problem(with: selection, displays: displays.map(\.info)) { return problem }
        return recording.isRecording ? RecordingError.alreadyStarted : nil
    }

    /// The displays the take records whole, each at its frame rate: the chosen ones in Display mode, the area's in
    /// Area mode, none in Window mode nor for an iPhone or iPad.
    var recordedDisplays: [DisplayChoice] {
        let ids: [UInt32] =
            switch selection.mode {
            case .display: selection.displayIDs
            case .area: selection.area.map { [$0.displayID] } ?? []
            case .window, .device: []
            }
        return ids.compactMap { id in displays.first { $0.id == id } }
    }

    /// "Choose on Screen" in Display mode: that display alone.
    func choose(display id: UInt32) {
        selection.displayIDs = [id]
    }

    /// A display's row: marked, or no longer; the displays keep the order of the list.
    func toggle(display id: UInt32) {
        var chosen = Set(selection.displayIDs)
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
        selection.displayIDs = displays.map(\.id).filter(chosen.contains)
    }

    /// The quick settings a take records with: the frame rates the settings show, for its displays, the window and
    /// the camera.
    var recordedQuick: QuickSettings {
        var quick = quick
        for display in recordedDisplays {
            quick.framesPerSecondByDisplay[display.id] = framesPerSecond(for: display)
        }
        quick.windowFramesPerSecond = Self.offered(quick.windowFramesPerSecond)
        quick.cameraFramesPerSecond = Self.offered(quick.cameraFramesPerSecond)
        return quick
    }

    /// Saves the selection and the settings and starts the take, at the frame rates the settings show. The
    /// take's phase takes the island to the countdown (or the wings).
    func record() {
        guard recordProblem == nil else { return }
        let quick = recordedQuick
        var settings = store.settings
        settings.selection = selection
        settings.quick = quick
        store.settings = settings
        recording.startRecording(selection: selection, settings: quick)
    }

    /// Area mode's saved areas and proportion, changed and saved at once, whatever else Record saves.
    func setAreaSettings(saved: SavedAreas? = nil, lock: AspectLock? = nil) {
        if let saved { savedAreas = saved }
        if let lock { aspectLock = lock }
        var settings = store.settings
        settings.savedAreas = savedAreas
        settings.aspectLock = aspectLock
        store.settings = settings
    }
}

/// The open island (700 × 400, notch design §5.2): the mode, what to record (displays with the desktops, a
/// window, or an area), the camera, audio and the teleprompter's switch, the settings, the encoder's load and
/// Record, and above Record why a jump to another desktop posted nothing and why the last take could not start.
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
                        case .device: .iPhone
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
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(GlassButtonStyle(shape: .circle))
            .help(Text("Close"))
            .accessibilityLabel(Text("Close"))
        }
    }

    // MARK: - What to record

    @ViewBuilder
    private var whatToRecord: some View {
        ColumnTitle(text: Text("What to Record"), icon: modeIcon)
        switch panel.selection.mode {
        case .display: displayColumn
        case .window: WindowChoiceColumn(panel: panel, send: send)
        case .area: AreaChoiceColumn(panel: panel, send: send)
        case .device: EmptyView()  // the devices' column comes with the iPhone tab (plan P17)
        }
    }

    private var modeIcon: String {
        switch panel.selection.mode {
        case .display: "display"
        case .window: "macwindow"
        case .area: "viewfinder"
        case .device: "iphone"
        }
    }

    /// Every display, each marked or not: a take records the marked ones. More than two scroll, so the desktops
    /// keep their place.
    @ViewBuilder
    private var displayColumn: some View {
        let rows = VStack(spacing: 2) {
            ForEach(panel.displays) { display in
                ChoiceRow(
                    title: Text(verbatim: display.name), subtitle: Text(verbatim: display.resolution),
                    isChosen: panel.selection.displayIDs.contains(display.id),
                    choose: { panel.toggle(display: display.id) },
                    hovering: { panel.highlight($0 ? display.id : nil) })
            }
        }
        if panel.displays.count > 2 {
            ScrollView { rows }
                .scrollIndicators(.automatic)
                .frame(maxHeight: Self.displayRowsHeight)
        } else {
            rows
        }
        Button { send(.beganChoosing) } label: {
            Label("Choose on Screen", systemImage: "display")
        }
        .buttonStyle(GlassButtonStyle())
        ColumnSection(title: Text("Desktop", comment: "A display's only desktop (Space), and the open island's section of desktops")) {
            DesktopsList(model: desktops, layout: .column)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Two displays and half of a third: the half says there are more.
    private static let displayRowsHeight = 104.0

    // MARK: - Camera

    private enum CameraTag: Hashable {
        case systemDefault
        case device(String)
    }

    /// The switch, and with the camera on which camera, the bubble's shape and size, and how to place it; they
    /// materialize as the island's content does when it is turned on. Off, a symbol and a line say so; once camera
    /// access was refused, the switch stays off and the card says how to allow it.
    @ViewBuilder
    private var camera: some View {
        ColumnTitle(text: Text("Camera"), icon: "video.fill") {
            Toggle(isOn: Binding(get: { panel.isCameraOn }, set: { panel.setCamera(on: $0) })) { Text("Camera") }
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .disabled(panel.camera.permission == .denied || panel.camera.isAsking)
        }
        ZStack(alignment: .top) {
            if panel.isCameraOn {
                cameraControls
                    .transition(reduceMotion ? .islandFade : .islandContent)
            } else {
                CameraOffState(isDenied: panel.camera.permission == .denied) { panel.camera.openSettings() }
                    .transition(reduceMotion ? .islandFade : .islandContent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.island(Motion.islandExpand, reduceMotion: reduceMotion), value: panel.isCameraOn)
    }

    /// Which camera, the bubble's shape and size, and how to place it.
    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: Column<EmptyView>.spacing) {
            Picker(selection: cameraDevice) {
                Text("System Default").tag(CameraTag.systemDefault)
                ForEach(cameraRows) { row in
                    Text(verbatim: row.name).tag(CameraTag.device(row.id))
                }
            } label: {
                Text("Camera")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            ColumnSection(title: Text("Shape", comment: "The camera bubble's shape")) {
                GlassSegmented(
                    items: CameraShape.allCases.map { shape in
                        .init(value: shape, title: Text(shape.title), icon: shape.symbol, iconOnly: true)
                    },
                    selection: Binding(get: { panel.camera.style.shape }, set: { shape in panel.camera.update { $0.shape = shape } }),
                    compact: true, fills: true)
            }
            ColumnSection(title: Text("Size", comment: "The camera's size, or the cursor's")) {
                GlassSegmented(
                    items: CameraStyle.sizes.map { size in .init(value: size.size, title: Text(size.title)) },
                    selection: Binding(get: { panel.camera.style.size }, set: { size in panel.camera.update { $0.size = size } }),
                    compact: true, fills: true)
            }
            ColumnNote(text: Text("Drag the bubble to place it. This is how the video starts; you can change it in the editor."))
        }
    }

    /// The connected cameras, and the chosen one if it is not connected now (by its ID).
    private var cameraRows: [CaptureDevice] {
        var rows = panel.cameras
        if case .device(let id) = panel.selection.camera, !rows.contains(where: { $0.id == id }) {
            rows.append(CaptureDevice(id: id, name: id))
        }
        return rows
    }

    private var cameraDevice: Binding<CameraTag> {
        Binding(
            get: {
                if case .device(let id) = panel.selection.camera { .device(id) } else { .systemDefault }
            },
            set: { tag in
                guard panel.isCameraOn else { return }
                switch tag {
                case .systemDefault: panel.selection.camera = .systemDefault
                case .device(let id): panel.selection.camera = .device(uniqueID: id)
                }
            })
    }

    // MARK: - Audio and script

    private enum MicrophoneTag: Hashable {
        case systemDefault, off
        case device(String)
    }

    @ViewBuilder
    private var audioAndScript: some View {
        ColumnTitle(text: Text("Audio and Script"), icon: "mic.fill")
        ColumnSection(title: Text("Microphone")) {
            MicrophoneLevelRow(preview: panel.levelPreview, choice: panel.selection.microphone)
        } content: {
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
            MicrophoneModeRow(preview: panel.levelPreview)
        }
        ColumnSection(title: Text("System Audio")) {
            SystemAudioPicker(panel: panel)
        }
        // A switch row: its name with its symbol, the switch at the right.
        HStack(spacing: 6) {
            Label {
                Text("Teleprompter")
            } icon: {
                Image(systemName: "text.alignleft").symbolRenderingMode(.hierarchical).opacity(0.75)
            }
            .font(.system(size: 12.5))
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            Toggle(isOn: panel.teleprompter.isOn) { Text("Teleprompter") }
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
        }
        .frame(height: ColumnTitle<EmptyView>.height)
        .padding(.top, 2)
        Spacer(minLength: 0)
    }

    /// The connected microphones, and the chosen one if it is not connected now (by its ID).
    private var microphoneRows: [CaptureDevice] {
        var rows = panel.microphones
        if case .device(let id) = panel.selection.microphone, !rows.contains(where: { $0.id == id }) {
            rows.append(CaptureDevice(id: id, name: id))
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
        HStack(spacing: 8) {
            Button { panel.showsSettings.toggle() } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(GlassButtonStyle(isOn: panel.showsSettings))
            Button { panel.openLibrary() } label: {
                Label("Library", systemImage: "square.grid.2x2")
            }
            .buttonStyle(GlassButtonStyle(isOn: false))
            Spacer(minLength: 8)
            LoadIndicator(verdict: panel.load) { panel.showsSettings = true }
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

/// The camera card while the camera is off: a symbol and a line, and once access was refused how to allow it.
private struct CameraOffState: View {
    let isDenied: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash")
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
                .opacity(0.6)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .accessibilityHidden(true)
            VStack(spacing: 3) {
                if isDenied {
                    Text("Camera access is off.")
                        .font(.system(size: 12.5, weight: .medium))
                        .opacity(0.85)
                } else {
                    Text("Camera Off", comment: "The open island's camera card while the camera is off")
                        .font(.system(size: 12.5, weight: .medium))
                        .opacity(0.85)
                    Text("Turn it on to place the bubble.", comment: "The open island's camera card while the camera is off: what the switch does")
                        .font(.system(size: 11))
                        .opacity(0.55)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            if isDenied {
                Button(action: openSettings) {
                    Text("Open Settings", comment: "Opens the camera's privacy settings in System Settings")
                }
                .buttonStyle(GlassButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 6)
        // In the middle of what the card has under its title, a little above center.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 18)
    }
}

/// The chosen microphone's live level (plan decision 31), heard while the panel shows it, at the right of the
/// microphone's name: nothing without microphone access (asked for when Record is clicked) or with the microphone
/// off.
private struct MicrophoneLevelRow: View {
    let preview: MicrophoneLevelPreview
    let choice: DeviceChoice

    var body: some View {
        // Always there, so it appears and disappears with the panel whether or not it shows the meter.
        Color.clear
            .frame(width: 28, height: 12)
            .overlay(alignment: .trailing) {
                if preview.isListening {
                    LevelMeter(peak: { preview.peakDecibels }, bars: 6, height: 12)
                }
            }
            .onAppear { preview.listen(to: choice) }
            .onChange(of: choice) { preview.listen(to: choice) }
            .onDisappear { preview.listen(to: nil) }
    }
}

// MARK: - Disabled with help

extension View {
    /// Disabled inside, with `help` on a container outside: a disabled control shows no help.
    func disabledWithHelp(_ help: String) -> some View {
        HStack(spacing: 0) { disabled(true) }
            .contentShape(Rectangle())
            .help(help)
    }
}
