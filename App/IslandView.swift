// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Observation
import SwiftUI

/// What the island's SwiftUI content shows; `IslandPanel` keeps it up to date.
@MainActor @Observable
final class IslandModel {
    /// The state whose content is shown; changed inside an animation, so contents come and go with
    /// their transitions.
    var state = IslandState.rest
    /// The screen the island is on.
    var top: ScreenTop
    /// The outline as it is on screen at this moment, while the spring moves it.
    var outline: IslandShape
    var reduceMotion: Bool
    var reduceTransparency: Bool
    /// The open panel's choices, while the island is open or choosing.
    var panel: OpenPanelModel?
    /// The open recording island asks whether to restart the take.
    var isConfirmingRestart = false
    /// The right wing's warning icon (`IslandMachine.attention`).
    var attention: NoticePresentation?
    /// Why the last take could not start, while the open panel says so (`IslandMachine.hasStartFailure`).
    var startFailure: String?

    /// The take the island shows.
    @ObservationIgnored let recording: RecordingController
    /// The global shortcuts, which the island names.
    @ObservationIgnored let hotKeys: HotKeyCenter
    /// The teleprompter's settings, for its switch in the open recording island.
    @ObservationIgnored let teleprompter: TeleprompterSetting
    /// The desktops of the island's display, in the open island and the open recording island.
    @ObservationIgnored let desktops: DesktopsModel
    /// What the content does to the island.
    @ObservationIgnored var send: (IslandEvent) -> Void = { _ in }

    init(
        recording: RecordingController, hotKeys: HotKeyCenter, teleprompter: TeleprompterSetting, desktops: DesktopsModel,
        top: ScreenTop, reduceMotion: Bool, reduceTransparency: Bool
    ) {
        self.recording = recording
        self.hotKeys = hotKeys
        self.teleprompter = teleprompter
        self.desktops = desktops
        self.top = top
        outline = IslandGeometry.shape(.rest, on: top)
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
    }

    /// Under the notch, the band at the top where nothing can be seen.
    var notchBand: Double { top.notch == nil ? 0 : top.menuBarHeight }
}

/// The island's content, cut to its outline on its surface. Only the outline changes on every frame of
/// the spring; the content of each state keeps the size of its state and is cut while the island grows
/// or shrinks.
struct IslandView: View {
    let model: IslandModel

    var body: some View {
        let outline = model.outline
        // The window's size, whatever the content's (`minWidth`/`minHeight` 0: without them a frame takes the
        // size of a larger child, and the hosting view centers it): the surface and the cut follow the
        // window, and the content stays pinned to its top.
        IslandContent(model: model)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .islandGlass(
                IslandOutline(outline), black: isBlack, topBand: model.notchBand, reduceTransparency: model.reduceTransparency)
            .environment(\.colorScheme, .dark)
            .environment(\.islandReduceMotion, model.reduceMotion)
    }

    /// At rest, peeking and in its recording wings, under the notch the island is all black, like the notch.
    private var isBlack: Bool {
        guard model.top.notch != nil else { return false }
        switch model.state {
        case .rest, .peek, .recording: return true
        case .open, .choosing, .countdown, .recordingOpen, .notice, .saving, .saved: return false
        }
    }
}

/// The content of the current state; the one that is left fades out while the new one appears.
private struct IslandContent: View {
    let model: IslandModel

    var body: some View {
        let shape = IslandGeometry.shape(model.state, on: model.top)
        ZStack(alignment: .top) {
            content(model.state)
                .frame(width: shape.width, height: shape.height, alignment: .top)
                .id(Self.key(model.state))
                .transition(model.reduceMotion ? .islandFade : .islandContent)
        }
        // Each state's content keeps its own size, centered and from the top of the window, which cuts it.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    /// Which content a state shows: a new key is a new content, with its transition. Every second of the
    /// countdown is the same content, whose number changes inside it, and so is every notice.
    private static func key(_ state: IslandState) -> Int {
        switch state {
        case .rest: 0
        case .peek: 1
        case .open: 2
        case .choosing: 3
        case .countdown: 4
        case .recording: 5
        case .recordingOpen: 6
        case .notice: 7
        case .saving: 8
        case .saved: 9
        }
    }

    @ViewBuilder
    private func content(_ state: IslandState) -> some View {
        switch state {
        case .rest:
            // Nothing to see: under a notch, a click opens it.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.send(.clicked) }
        case .peek:
            BelowTheNotch(band: model.notchBand) { PeekRow(shortcut: model.hotKeys.bindings.combos[.islandOrStop]) }
                .contentShape(Rectangle())
                .onTapGesture { model.send(.clicked) }
        case .open:
            if let panel = model.panel {
                IslandOpenPanel(
                    panel: panel, desktops: model.desktops, topInset: model.notchBand, startFailure: model.startFailure, send: model.send)
            }
        case .choosing:
            BelowTheNotch(band: model.notchBand) { ChoosingRow(panel: model.panel, send: model.send) }
        case .countdown(let remaining):
            CountdownView(remaining: remaining, topInset: model.notchBand)
        case .recording:
            RecordingWings(
                recording: model.recording, notchWidth: model.top.notch.map { Double($0.width) }, attention: model.attention)
        case .recordingOpen:
            IslandRecordingPanel(recording: model.recording, model: model, topInset: model.notchBand, send: model.send)
        case .notice(let notice):
            // Under the notch, in the 40 pt below the menu bar.
            BelowTheNotch(band: model.notchBand) {
                IslandNoticeLine(notice: notice, closeError: model.recording.lastCloseError)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
            }
        case .saving:
            BelowTheNotch(band: model.notchBand) { IslandSavingView() }
        case .saved(let take):
            IslandSavedView(take: take, recording: model.recording, topInset: model.notchBand, send: model.send)
        }
    }
}

/// Centers its content in what is left under the notch's band.
private struct BelowTheNotch<Content: View>: View {
    let band: Double
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: band)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The record icon, "New Recording" and the island's shortcut, if it has one.
private struct PeekRow: View {
    let shortcut: KeyCombo?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "record.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
                .font(.system(size: 12))
            Text("New Recording")
                .font(.system(size: 12, weight: .medium))
            if let shortcut { KeyCap(text: shortcut.shownString) }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
    }
}

/// While choosing on the screen: what to do for the mode chosen, how to go back, and Done.
private struct ChoosingRow: View {
    let panel: OpenPanelModel?
    let send: (IslandEvent) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12))
            hint
                .font(.system(size: 12, weight: .medium))
                .contentTransition(.opacity)
            KeyCap(text: String(localized: "Esc to go back"))
            Button { send(.endedChoosing) } label: {
                Text("Done")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
    }

    private var mode: CaptureMode { panel?.selection.mode ?? .display }

    /// iPhone mode chooses nothing on the Mac's screen: if it came to choosing, it would be a display, as without a panel.
    private var symbol: String {
        switch mode {
        case .display, .device: "display"
        case .window: "macwindow"
        case .area: "viewfinder"
        }
    }

    private var hint: Text {
        switch mode {
        case .display, .device: Text("Click a display to record it.")
        case .window: Text("Click a window to record it.")
        case .area:
            panel?.selection.area == nil ? Text("Drag to draw the area.") : Text("Move the area or change its size.")
        }
    }
}

extension AnyTransition {
    /// A state's content materializing (opacity 0 → 1, blur 10 → 0, scale 0.94 → 1 with the opening spring,
    /// 60 ms after the island starts to change) and fading out (170 ms, blur 0 → 8). Notch design §5.3.
    static var islandContent: AnyTransition {
        let enter = Motion.islandExpand
        return .asymmetric(
            insertion: .modifier(
                active: Materialized(opacity: 0, blur: Motion.contentEnterBlur, scale: Motion.contentEnterScale),
                identity: Materialized(opacity: 1, blur: 0, scale: 1)
            )
            .animation(.spring(response: enter.response, dampingFraction: enter.damping).delay(Motion.contentDelay.timeInterval)),
            removal: .modifier(
                active: Materialized(opacity: 0, blur: Motion.contentExitBlur, scale: 1),
                identity: Materialized(opacity: 1, blur: 0, scale: 1)
            )
            .animation(.easeIn(duration: Motion.contentExit.timeInterval)))
    }

    /// With "Reduce motion": a fade, without scale or blur.
    static var islandFade: AnyTransition {
        .opacity.animation(.easeInOut(duration: Motion.reducedMotionFade.timeInterval))
    }
}

private struct Materialized: ViewModifier {
    let opacity: Double
    let blur: Double
    let scale: Double

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blur)
            .scaleEffect(scale, anchor: .top)
    }
}
