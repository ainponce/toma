// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Observation
import QuartzCore
import SwiftUI

/// The teleprompter's settings (`RecorderSettings.teleprompter`): the one place they are read and saved, for
/// the teleprompter and the island's switches, which all show them as they are now. Every change is saved at
/// once, in its range (`TeleprompterSettings.clamped()`).
@MainActor @Observable
final class TeleprompterSetting {
    private(set) var value: TeleprompterSettings

    @ObservationIgnored private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
        value = store.settings.teleprompter.clamped()
    }

    func update(_ change: (inout TeleprompterSettings) -> Void) {
        var changed = value
        change(&changed)
        changed = changed.clamped()
        guard changed != value else { return }
        value = changed
        var settings = store.settings
        settings.teleprompter = changed
        store.settings = settings
    }

    /// Whether it shows, for a switch.
    var isOn: Binding<Bool> {
        Binding(get: { self.value.isOn }, set: { isOn in self.update { $0.isOn = isOn } })
    }
}

/// The teleprompter (notch design §5.4): a glass panel 640 × 160 that hangs `TeleprompterLayout.gap` under the
/// island and follows it on every step of its spring (`follow`, called from the island's display link), shown
/// where `TeleprompterLayout.isVisible` says. The script goes up at the chosen speed only as
/// `TeleprompterRules.scrolls` says, stepped by a display link of its own that rests once the script is at its
/// end; it goes back to the top with each new take (`RecordingController.takeSerial`) and as
/// `TeleprompterRules.startsFromTheTop` says, so it never shows where the last take left it. It is never key,
/// except while its script is edited, which ends as `TeleprompterRules` says.
@MainActor
final class TeleprompterPanel: NSObject, NSWindowDelegate {
    var reduceMotion = false {
        didSet { model.reduceMotion = reduceMotion }
    }
    var reduceTransparency = false {
        didSet { model.reduceTransparency = reduceTransparency }
    }
    /// The teleprompter came on the screen or left it: what hangs under the island changed.
    var visibilityChanged: () -> Void = {}
    /// The teleprompter lost the keyboard.
    var resignedKey: () -> Void = {}
    /// Editing is over while the teleprompter has the keyboard: the island takes it back if it is in a state
    /// that uses it (and says so); otherwise it goes back to the app in front.
    var islandTakesKeyboard: () -> Bool = { false }

    /// On the screen, also while it fades out.
    var isShown: Bool { panel.isVisible }

    private let setting: TeleprompterSetting
    private let recording: RecordingController
    private let panel: FloatingPanel
    private let model: TeleprompterModel
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    private var island = IslandState.rest
    /// The take whose script is being read (`RecordingController.takeSerial`).
    private var takeSerial: Int
    /// The panel is fading out, to leave the screen.
    private var isHiding = false
    /// The island is changing screens: the teleprompter faded out with it, and fades in with it.
    private var isChangingScreens = false

    /// After a hitch the script goes up at most this much time at once.
    private static let longestStep: CFTimeInterval = 0.1

    init(setting: TeleprompterSetting, recording: RecordingController) {
        self.setting = setting
        self.recording = recording
        takeSerial = recording.takeSerial
        model = TeleprompterModel(setting: setting)
        let frame = NSRect(x: 0, y: 0, width: TeleprompterLayout.width, height: TeleprompterLayout.height)
        panel = FloatingPanel(contentRect: frame, level: FloatingPanel.floatingLevel, ignoresMouseEvents: false)
        super.init()

        let content = FloatingHostingView.make(TeleprompterView(model: model))
        content.frame = frame
        panel.contentView = content
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.endEditing() }
        panel.onClose = { [weak self] in self?.endEditing() }
        model.beginEditing = { [weak self] in self?.beginEditing() }
        model.endEditing = { [weak self] in self?.endEditing() }
        model.scrollLimitChanged = { [weak self] in self?.updateScrolling() }
        let link = content.displayLink(target: self, selector: #selector(scrollTick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        observe()
    }

    /// The island is now at `islandFrame`: the teleprompter goes under it, in the same frame.
    func follow(_ islandFrame: CGRect) {
        let origin = TeleprompterLayout.frame(below: islandFrame).origin
        guard origin != panel.frame.origin else { return }
        panel.setFrameOrigin(origin)
    }

    /// The island is now in `state`.
    func update(island state: IslandState) {
        let before = island
        island = state
        if TeleprompterRules.endsEditing(from: before, to: state) { endEditing() }
        showOrHide()
    }

    /// The island fades out to change screens (`leaving`), or back in on its new one: the teleprompter fades
    /// with it, for as long.
    func fadeWithIsland(leaving: Bool, duration: TimeInterval) {
        isChangingScreens = leaving
        guard panel.isVisible, !isHiding else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = leaving ? 0 : 1
        }
    }

    /// The keyboard went elsewhere (by now the panel is no longer key, so it is not taken back).
    func windowDidResignKey(_ notification: Notification) {
        if TeleprompterRules.endsEditingOnLosingKeyboard(island: island) { endEditing() }
        resignedKey()
    }

    // MARK: - The take

    /// The take, and every setting: whether it shows, and what can change how far the script goes up.
    private func observe() {
        withObservationTracking {
            _ = setting.value
            _ = recording.phase
            _ = recording.isUserPaused
            _ = recording.isPaused
            _ = recording.takeSerial
        } onChange: { [weak self] in
            // Called before the change: read it once it is made.
            Task { @MainActor in self?.changed() }
        }
    }

    private func changed() {
        observe()
        if recording.takeSerial != takeSerial {
            takeSerial = recording.takeSerial
            model.scroll.reset()
        }
        showOrHide()
    }

    private var isRecordingATake: Bool {
        if case .recording = recording.phase { true } else { false }
    }

    private var isRunning: Bool {
        TeleprompterRules.scrolls(
            phase: recording.phase, isUserPaused: recording.isUserPaused, isPaused: recording.isPaused, isEditing: model.isEditing)
    }

    // MARK: - Showing and hiding

    private func showOrHide() {
        if TeleprompterLayout.isVisible(isOn: setting.value.isOn, island: island) {
            let returning = !panel.isVisible || isHiding
            isHiding = false
            if TeleprompterRules.startsFromTheTop(returning: returning, isRecording: isRecordingATake) { model.scroll.reset() }
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                visibilityChanged()
            }
            if panel.alphaValue < 1, !isChangingScreens { fade(to: 1) }
        } else {
            // Unless the island takes it back, the keyboard goes back to the app in front once the panel is
            // ordered out.
            endEditing(reordering: false)
            if panel.isVisible, !isHiding {
                isHiding = true
                fade(to: 0) { [weak self] in
                    guard let self, isHiding else { return }
                    isHiding = false
                    panel.orderOut(nil)
                    visibilityChanged()
                    updateScrolling()
                }
            }
        }
        updateScrolling()
    }

    private func fade(to alpha: CGFloat, then completion: (@MainActor () -> Void)? = nil) {
        let duration = (model.reduceMotion ? Motion.reducedMotionFade : Motion.contentExit).timeInterval
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    // MARK: - Editing

    /// The script becomes a text field: the panel is key, without activating the app, while it is edited.
    private func beginEditing() {
        guard !model.isEditing, panel.isVisible, !isHiding else { return }
        model.isEditing = true
        panel.wantsKey = true
        panel.makeKey()
        updateScrolling()
    }

    /// Back to reading. If the panel has the keyboard, it goes back to the island if the island uses it, and
    /// otherwise to the app in front: the window server gives it back when the panel is ordered out and, if
    /// `reordering`, in again (without, the panel is about to be ordered out).
    private func endEditing(reordering: Bool = true) {
        guard model.isEditing else { return }
        model.isEditing = false
        panel.wantsKey = false
        if panel.isKeyWindow, !islandTakesKeyboard(), reordering {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        updateScrolling()
    }

    // MARK: - Scrolling

    /// The display link runs only while the teleprompter is seen and its script goes up, and has somewhere
    /// to go: it rests at the end, or with a script shorter than the reading area, until the text changes.
    private func updateScrolling() {
        guard let displayLink else { return }
        let scrolls = panel.isVisible && !isHiding && isRunning && !model.scroll.isAtEnd(maximum: model.maximumOffset)
        if scrolls, displayLink.isPaused { lastFrameTime = nil }
        displayLink.isPaused = !scrolls
    }

    @objc private func scrollTick(_ link: CADisplayLink) {
        let time = link.timestamp
        let seconds = lastFrameTime.map { min(max(time - $0, 0), Self.longestStep) } ?? max(link.targetTimestamp - link.timestamp, 0)
        lastFrameTime = time
        var scroll = model.scroll
        scroll.advance(seconds: seconds, speed: setting.value.speed, isRunning: isRunning, maximum: model.maximumOffset)
        if scroll != model.scroll { model.scroll = scroll }
        if scroll.isAtEnd(maximum: model.maximumOffset) { updateScrolling() }
    }
}

/// What the teleprompter's SwiftUI content shows; `TeleprompterPanel` keeps it up to date.
@MainActor @Observable
private final class TeleprompterModel {
    var scroll = TeleprompterScroll()
    var isEditing = false
    var reduceMotion = false
    var reduceTransparency = false
    /// The script as it is read, with the room before and after it (`TeleprompterView.leadIn`, `leadOut`).
    private(set) var contentHeight = 0.0

    @ObservationIgnored let setting: TeleprompterSetting
    @ObservationIgnored var beginEditing: () -> Void = {}
    @ObservationIgnored var endEditing: () -> Void = {}
    /// How far the script can go up changed.
    @ObservationIgnored var scrollLimitChanged: () -> Void = {}

    init(setting: TeleprompterSetting) {
        self.setting = setting
    }

    /// How far the script can go up: until its last line is at the bottom of the clear band.
    var maximumOffset: Double { Self.maximumOffset(contentHeight: contentHeight) }

    /// The script was laid out again (another size, or edited): the scroll keeps its place in it.
    func contentHeightChanged(to height: Double) {
        guard height != contentHeight else { return }
        var scroll = scroll
        scroll.contentHeightChanged(from: contentHeight, to: height, maximum: Self.maximumOffset(contentHeight: height))
        contentHeight = height
        if scroll != self.scroll { self.scroll = scroll }
        scrollLimitChanged()
    }

    private static func maximumOffset(contentHeight: Double) -> Double {
        contentHeight - TeleprompterView.readingHeight
    }
}

/// The script, large and centered, fading out at the top and the bottom; the controls under it. The opacity
/// chosen is that of a dark tint over the glass (the glass itself never changes: as in the prototype) and of
/// the script; the controls stay as they are.
private struct TeleprompterView: View {
    static let barHeight = 38.0
    static let readingHeight = TeleprompterLayout.height - barHeight
    /// The first line starts here, in the clear band under the top fade.
    static let leadIn = 40.0
    /// Room after the last line, so it can go up into the clear band above the bottom fade.
    static let leadOut = readingHeight * 0.3
    static let radius = 24.0
    /// The prototype's tint over the glass, `tintOpacity` × the opacity chosen.
    static let tint = Color(red: 16 / 255, green: 16 / 255, blue: 22 / 255)
    static let tintOpacity = 0.78

    let model: TeleprompterModel

    var body: some View {
        let outline = IslandOutline(IslandShape(
            width: TeleprompterLayout.width, height: TeleprompterLayout.height, bottomRadius: Self.radius, roundsTopCorners: true))
        VStack(spacing: 0) {
            Group {
                if model.isEditing {
                    ScriptEditor(model: model)
                } else {
                    ScriptReader(model: model)
                }
            }
            .frame(height: Self.readingHeight)
            TeleprompterControls(model: model)
                .frame(height: Self.barHeight)
                .overlay(alignment: .top) { Color.white.opacity(0.1).frame(height: 1) }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background {
            // With "Reduce transparency" the glass is solid, and the tint over it keeps it so.
            Self.tint
                .opacity(Self.tintOpacity * model.setting.value.opacity)
                .islandGlass(outline, black: false, topBand: 0, reduceTransparency: model.reduceTransparency)
        }
        .clipShape(outline)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.islandReduceMotion, model.reduceMotion)
    }
}

/// The script as it is read: centered, semibold, at the chosen size and opacity (35 % at least), moved up by
/// the scroll. Without a script it says "Write your script…", and a click on it edits it.
private struct ScriptReader: View {
    let model: TeleprompterModel

    /// Between the script and the panel's sides.
    private static let sideInset = 28.0

    var body: some View {
        let settings = model.setting.value
        let isEmpty = settings.script.isEmpty
        Group {
            if isEmpty {
                Text("Write your script…").opacity(0.45)
            } else {
                Text(verbatim: settings.script)
            }
        }
        .font(.system(size: settings.fontSize, weight: .semibold))
        .tracking(-0.005 * settings.fontSize)
        .lineSpacing(0.22 * settings.fontSize)
        .multilineTextAlignment(.center)
        .frame(width: TeleprompterLayout.width - 2 * Self.sideInset)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, TeleprompterView.leadIn)
        .padding(.bottom, TeleprompterView.leadOut)
        .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { model.contentHeightChanged(to: $0) }
        .offset(y: -model.scroll.offset)
        // The reading area's size, whatever the script's: it stays pinned to the top, and is cut.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.24),
                    .init(color: .black, location: 0.7), .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        }
        .opacity(max(0.35, settings.opacity))
        .contentShape(Rectangle())
        .onTapGesture {
            if isEmpty { model.beginEditing() }
        }
    }
}

/// The script in a text field, which has the keyboard while it shows.
private struct ScriptEditor: View {
    let model: TeleprompterModel
    @FocusState private var isFocused: Bool

    var body: some View {
        let script = Binding(get: { model.setting.value.script }, set: { script in model.setting.update { $0.script = script } })
        TextEditor(text: script)
            .font(.system(size: 13))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            // The field's border says it has the keyboard.
            .focusEffectDisabled()
            .focused($isFocused)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .overlay(alignment: .topLeading) {
                if script.wrappedValue.isEmpty {
                    Text("Write your script…")
                        .font(.system(size: 13))
                        .opacity(0.45)
                        .padding(.leading, 11)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.32))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(isFocused ? 0.45 : 0.18)))
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .onAppear { isFocused = true }
    }
}

/// Edit or Done and the text size on the left, the speed and the opacity with their values in the middle, and
/// "Not in the video", a quiet note rather than a control, on the right. Every change is saved.
private struct TeleprompterControls: View {
    let model: TeleprompterModel

    var body: some View {
        let setting = model.setting
        let settings = setting.value
        HStack(spacing: 10) {
            Button {
                model.isEditing ? model.endEditing() : model.beginEditing()
            } label: {
                Label {
                    model.isEditing ? Text("Done") : Text("Edit")
                } icon: {
                    Image(systemName: model.isEditing ? "checkmark" : "pencil").symbolRenderingMode(.hierarchical)
                }
                .contentTransition(.opacity)
            }
            .buttonStyle(GlassButtonStyle(compact: true))
            TextSizeControl(size: settings.fontSize) { steps in
                setting.update { $0.fontSize += Double(steps) * TeleprompterSettings.fontStep }
            }
            Spacer(minLength: 0)
            SliderControl(
                symbol: "gauge.with.dots.needle.33percent", title: Text("Speed"),
                value: Binding(get: { settings.speed }, set: { speed in setting.update { $0.speed = speed } }),
                range: TeleprompterSettings.speeds, step: 0.1,
                valueText: (settings.speed.formatted(.number.precision(.fractionLength(1)))) + "×")
            SliderControl(
                symbol: "circle.lefthalf.filled", title: Text("Opacity"),
                value: Binding(get: { settings.opacity }, set: { opacity in setting.update { $0.opacity = opacity } }),
                range: TeleprompterSettings.opacities, step: 0.05,
                valueText: settings.opacity.formatted(.percent.precision(.fractionLength(0))))
            Spacer(minLength: 0)
            Label {
                Text("Not in the video")
            } icon: {
                Image(systemName: "eye.slash").symbolRenderingMode(.hierarchical)
            }
            .labelStyle(TightLabelStyle())
            .font(.system(size: 11))
            .opacity(0.5)
            .fixedSize()
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .padding(.horizontal, 12)
    }
}

/// A label with its icon close to its title.
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

/// The text size, in steps of `TeleprompterSettings.fontStep`: smaller and larger, each disabled at its end.
private struct TextSizeControl: View {
    let size: Double
    /// −1 smaller, +1 larger.
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "textformat.size")
                .symbolRenderingMode(.hierarchical)
                .opacity(0.75)
                .padding(.trailing, 2)
            button("minus", steps: -1, isEnabled: size > TeleprompterSettings.fontSizes.lowerBound)
            button("plus", steps: 1, isEnabled: size < TeleprompterSettings.fontSizes.upperBound)
        }
        // The help is on a container: a disabled button shows none.
        .contentShape(Rectangle())
        .help(Text("Text Size"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Text Size"))
        .accessibilityValue(Text(verbatim: "\(Int(size)) pt"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private func button(_ symbol: String, steps: Int, isEnabled: Bool) -> some View {
        Button { step(steps) } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(GlassButtonStyle(shape: .circle))
        .disabled(!isEnabled)
    }
}

/// A slider with its symbol, and its value after it in tabular digits; its title is its help and what VoiceOver
/// reads. Continuous under the pointer (no tick marks), its value kept to `step`.
private struct SliderControl: View {
    let symbol: String
    let title: Text
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// The value as it is shown and read.
    let valueText: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .opacity(0.75)
                .accessibilityHidden(true)
            Slider(value: stepped, in: range) { title }
                .labelsHidden()
                .controlSize(.mini)
                .tint(.white)
                .frame(width: 76)
                .accessibilityValue(Text(verbatim: valueText))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: stepped.wrappedValue = value + step
                    case .decrement: stepped.wrappedValue = value - step
                    @unknown default: break
                    }
                }
            Text(verbatim: valueText)
                .font(.system(size: 11))
                .monospacedDigit()
                .opacity(0.6)
                .frame(width: 32, alignment: .leading)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .help(title)
    }

    /// The value, kept to `step` from the bottom of the range.
    private var stepped: Binding<Double> {
        Binding(
            get: { value },
            set: { new in
                let steps = ((new - range.lowerBound) / step).rounded()
                value = min(max(range.lowerBound + steps * step, range.lowerBound), range.upperBound)
            })
    }
}
