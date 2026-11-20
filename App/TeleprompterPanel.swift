// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Analysis
import Observation
import ProjectFormat
import QuartzCore
import SwiftUI
import os

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
        #if DEBUG
        if isShowcase { return }
        #endif
        var settings = store.settings
        settings.teleprompter = changed
        store.settings = settings
    }

    /// Whether it shows, for a switch.
    var isOn: Binding<Bool> {
        Binding(get: { self.value.isOn }, set: { isOn in self.update { $0.isOn = isOn } })
    }

    #if DEBUG
    /// The teleprompter of a showcase shows `value`, which is never saved (nor what it changes).
    func showcase(_ value: TeleprompterSettings) {
        self.value = value.clamped()
        isShowcase = true
    }

    @ObservationIgnored private var isShowcase = false
    #endif
}

/// The teleprompter (notch design §5.4): a glass panel 640 × 160 that hangs `TeleprompterLayout.gap` under the
/// island and follows it on every step of its spring (`follow`, called from the island's display link), shown
/// where `TeleprompterLayout.isVisible` says. The script is read line by line as `TeleprompterLines` lays it out. It goes
/// up at the chosen speed only as `TeleprompterRules.scrolls` says, stepped by a display link of its own that rests once
/// the script is at its end; with "Follow the Voice" (phase 3 design §8.4) it goes instead where the voice is
/// (`TeleprompterVoice`): the line being read to the reading line with `Motion.timelineScroll` (at once with Reduce
/// Motion), what was said dimmed, unless a note says why it cannot. It starts again with each new take
/// (`RecordingController.takeSerial`) and as `TeleprompterRules.startOffset` says: from the top, or from the sentence a
/// re-record begins at, never where the last take left it. During a re-record of a project with a script (`script.txt`)
/// it reads and writes that one, not the settings' (plan 3d, decision 11); it gives the script each take saves into its
/// project (`RecordingController.scriptToSave`). It is never key, except while its script is edited, which ends as
/// `TeleprompterRules` says.
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
    private let voice: TeleprompterVoice
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    private var island = IslandState.rest
    /// The take whose script is being read (`RecordingController.takeSerial`).
    private var takeSerial: Int
    /// Follow the Voice as it was last seen: turning it on during a take follows from the line being read.
    private var followedVoice: Bool
    /// The panel is fading out, to leave the screen.
    private var isHiding = false
    /// The island is changing screens: the teleprompter faded out with it, and fades in with it.
    private var isChangingScreens = false
    /// Where the script goes while it follows the voice.
    private var follow = SpringValue(value: 0, spring: Motion.timelineScroll)
    /// The re-record whose project's script it reads (`RecordingController.currentRequest`), from its countdown until
    /// it ends.
    private var rerecordPackage: URL?
    private var scriptLoad: Task<Void, Never>?
    /// Writes the project's script a second after the last change to it.
    private var scriptSave: Task<Void, Never>?
    /// The project's script was changed and not written yet.
    private var scriptChanged = false
    /// The writes of the project's script, each after the one before.
    private var scriptWrites: Task<Void, Never>?

    /// After a hitch the script goes up at most this much time at once.
    private static let longestStep: CFTimeInterval = 0.1
    /// How long after the last change the project's script is written.
    private static let scriptSaveDelay = Duration.seconds(1)
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Teleprompter")

    init(setting: TeleprompterSetting, recording: RecordingController) {
        self.setting = setting
        self.recording = recording
        takeSerial = recording.takeSerial
        followedVoice = setting.value.followsVoice
        voice = TeleprompterVoice(recording: recording)
        model = TeleprompterModel(setting: setting, voice: voice)
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
        model.projectScriptChanged = { [weak self] in self?.projectScriptChanged() }
        // Each take saves the script it reads into its project as it starts recording (decision 11).
        recording.scriptToSave = { [weak self] _ in self?.scriptToSave() }
        let link = content.displayLink(target: self, selector: #selector(scrollTick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        #if DEBUG
        showcase()
        #endif
        model.relayout()
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

    /// The take, every setting, and the voice: whether it shows, what it reads, and how far the script goes up.
    private func observe() {
        withObservationTracking {
            _ = setting.value
            _ = recording.phase
            _ = recording.isUserPaused
            _ = recording.isPaused
            _ = recording.takeSerial
            _ = recording.recordsMicrophone
            _ = recording.currentRequest
            _ = model.projectScript
            _ = voice.place
            _ = voice.note
        } onChange: { [weak self] in
            // Called before the change: read it once it is made.
            Task { @MainActor in self?.changed() }
        }
    }

    private func changed() {
        observe()
        followRerecord()
        if !model.isEditing { model.relayout() }
        if recording.takeSerial != takeSerial {
            takeSerial = recording.takeSerial
            startAgain()
        }
        let followsVoice = setting.value.followsVoice
        if followsVoice != followedVoice {
            followedVoice = followsVoice
            // Turned on: the voice is taken to be at the line being read (before the take, where it starts).
            if followsVoice { voice.restart(script: model.layout.words, at: wordBeingRead) }
        }
        voice.update(TeleprompterVoice.Take(
            followsVoice: followsVoice, isRecording: isRecordingATake, isPaused: recording.isUserPaused || recording.isPaused,
            serial: recording.takeSerial, recordsMicrophone: recording.recordsMicrophone))
        showOrHide()
    }

    private var isRecordingATake: Bool {
        if case .recording = recording.phase { true } else { false }
    }

    private var isRunning: Bool {
        TeleprompterRules.scrolls(
            phase: recording.phase, isUserPaused: recording.isUserPaused, isPaused: recording.isPaused, isEditing: model.isEditing)
    }

    /// The word the take starts at: the first of the sentence a re-record begins at (decision 12), if the script read is
    /// its project's, which the word is of; the start otherwise.
    private var startWord: Int? {
        guard model.projectScript != nil, let word = recording.currentRequest?.target?.scriptWord else { return nil }
        let words = model.layout.words
        guard !words.words.isEmpty else { return nil }
        return words.sentenceStart(of: word)
    }

    /// The first word of the line at the reading line now.
    private var wordBeingRead: Int {
        if !isRecordingATake, let startWord { return startWord }
        return TeleprompterFollow.word(
            atOffset: model.scroll.offset, lines: model.layout.lines, readingHeight: TeleprompterView.readingHeight,
            leadIn: TeleprompterView.leadIn)
    }

    /// Where the script starts if it comes back on the screen (`returning`) now, as `TeleprompterRules.startOffset` says
    /// (`isRecording` false: where a take starts, whatever records); `nil`: it stays where it is.
    private func startOffset(returning: Bool, isRecording: Bool) -> Double? {
        TeleprompterRules.startOffset(
            returning: returning, isRecording: isRecording, word: startWord, lines: model.layout.lines,
            readingHeight: TeleprompterView.readingHeight, leadIn: TeleprompterView.leadIn, maximum: model.maximumOffset)
    }

    /// The script starts again where a take starts, and the voice is followed from there: a new take, a restart, the
    /// teleprompter back on the screen without a take, or its project's script read.
    private func startAgain() {
        voice.restart(script: model.layout.words, at: startWord ?? 0)
        model.move(to: startOffset(returning: true, isRecording: false) ?? 0)
        follow = SpringValue(value: model.scroll.offset, spring: Motion.timelineScroll)
    }

    // MARK: - The project's script

    /// The script each take saves into its project as it starts recording: the one read, if the teleprompter is on (the
    /// controller saves none if it is empty, and never replaces a script a re-record's project has).
    private func scriptToSave() -> String? {
        setting.value.isOn ? model.script : nil
    }

    /// A re-record began (from its countdown): if its project has a script, the teleprompter reads it, and writes its
    /// changes into it; once it ends, whatever was changed last is written and the settings' script is back, as it was.
    private func followRerecord() {
        let package = recording.currentRequest?.target?.packageURL.standardizedFileURL
        guard package != rerecordPackage else { return }
        saveProjectScript()
        scriptLoad?.cancel()
        rerecordPackage = package
        model.projectScript = nil
        guard let package else { return }
        scriptLoad = Task { [weak self] in
            let script = await Task.detached { ProjectPackage(url: package).readScript() }.value
            guard let self, !Task.isCancelled, rerecordPackage == package, let script else { return }
            model.projectScript = script
            model.relayout()
            if !isRecordingATake { startAgain() }
            updateScrolling()
        }
    }

    /// The project's script was changed: written a second after the last change.
    private func projectScriptChanged() {
        scriptChanged = true
        scriptSave?.cancel()
        scriptSave = Task { [weak self] in
            try? await Task.sleep(for: Self.scriptSaveDelay)
            guard !Task.isCancelled else { return }
            self?.saveProjectScript()
        }
    }

    /// Writes the project's script now if it was changed, whole and atomic, off the main thread and after the writes
    /// before it (`ProjectPackage.writeScript`); a failure is only logged.
    private func saveProjectScript() {
        scriptSave?.cancel()
        scriptSave = nil
        guard scriptChanged, let package = rerecordPackage, let script = model.projectScript else { return }
        scriptChanged = false
        let previous = scriptWrites
        let logger = Self.logger
        scriptWrites = Task.detached {
            await previous?.value
            do {
                try ProjectPackage(url: package).writeScript(script)
            } catch {
                logger.error("Cannot save the script into \(package.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Showing and hiding

    private func showOrHide() {
        if TeleprompterLayout.isVisible(isOn: setting.value.isOn, island: island) {
            let returning = !panel.isVisible || isHiding
            isHiding = false
            if startOffset(returning: returning, isRecording: isRecordingATake) != nil {
                startAgain()
                voice.refreshAvailability()
            }
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
        model.relayout()
        updateScrolling()
    }

    // MARK: - Scrolling

    /// It follows the voice: on, and nothing says it cannot.
    private var isFollowing: Bool {
        setting.value.followsVoice && voice.note == nil
    }

    /// The display link runs only while the teleprompter is seen and its script moves: going up at its speed, until its
    /// end (or never, with a script shorter than the reading area); or, following the voice, until it reaches the line
    /// being read. With Reduce Motion, or unseen, it is there at once.
    private func updateScrolling() {
        guard let displayLink else { return }
        let onScreen = panel.isVisible && !isHiding
        let moves: Bool
        if isFollowing {
            let target = followTarget
            // Something else moved it (a reflow, a start): the spring starts from where it is now.
            if follow.isSettled, follow.value != model.scroll.offset {
                follow = SpringValue(value: model.scroll.offset, spring: Motion.timelineScroll)
            }
            if follow.target != target { follow.retarget(target, spring: Motion.timelineScroll) }
            if model.reduceMotion || !onScreen || model.isEditing {
                follow = SpringValue(value: target, spring: Motion.timelineScroll)
                model.move(to: target)
                moves = false
            } else {
                moves = !follow.isSettled
            }
        } else {
            moves = onScreen && isRunning && !model.scroll.isAtEnd(maximum: model.maximumOffset)
        }
        if moves, displayLink.isPaused { lastFrameTime = nil }
        displayLink.isPaused = !moves
    }

    /// Where the line of the next word to say is at the reading line.
    private var followTarget: Double {
        let layout = model.layout
        let word = min(voice.place.word, layout.words.words.count - 1)
        guard let line = layout.lines.line(ofWord: word) else { return 0 }
        return TeleprompterFollow.offset(
            showing: layout.lines.lines[line], readingHeight: TeleprompterView.readingHeight, leadIn: TeleprompterView.leadIn,
            maximum: model.maximumOffset)
    }

    @objc private func scrollTick(_ link: CADisplayLink) {
        let time = link.timestamp
        let seconds = lastFrameTime.map { min(max(time - $0, 0), Self.longestStep) } ?? max(link.targetTimestamp - link.timestamp, 0)
        lastFrameTime = time
        if isFollowing {
            follow.step(by: seconds)
            model.move(to: follow.value)
            if follow.isSettled { updateScrolling() }
            return
        }
        var scroll = model.scroll
        scroll.advance(seconds: seconds, speed: setting.value.speed, isRunning: isRunning, maximum: model.maximumOffset)
        if scroll != model.scroll { model.scroll = scroll }
        if scroll.isAtEnd(maximum: model.maximumOffset) { updateScrolling() }
    }

    // MARK: - Showcase

    #if DEBUG
    /// `TOMA_SHOWCASE_P3_TELEPROMPTER=follow` (with `-TomaShowcase island display`): the teleprompter on, following the
    /// voice in a script of its own at its word 12, what was said dimmed; `follow-note`, saying the language is missing
    /// instead. Nothing is saved. With `TOMA_SHOWCASE_P3_TELEPROMPTER_PNG=<path>`, two seconds after it shows, its
    /// content is drawn into a PNG at `<path>` by its views (the screen cannot be captured while it is locked).
    private func showcase() {
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("-TomaShowcase"),
              let variant = environment["TOMA_SHOWCASE_P3_TELEPROMPTER"], variant.hasPrefix("follow")
        else { return }
        let script = """
            Hola, soy Ana. Hoy les muestro cómo grabar la pantalla con Toma, paso a paso y sin cortes. Primero elijo la \
            ventana que quiero mostrar y prendo la cámara. Después leo este guion: el teleprompter me sigue mientras hablo, \
            y lo que ya dije queda más tenue. Si me equivoco, regrabo desde acá y sigo con la frase siguiente, en el mismo \
            proyecto.
            """
        setting.showcase(TeleprompterSettings(isOn: true, script: script, followsVoice: true))
        model.relayout()
        let note: TeleprompterFollow.Note? = variant == "follow-note" ? .missingLanguage("es-MX") : nil
        voice.showcase(script: model.layout.words, word: 12, note: note)
        if let path = environment["TOMA_SHOWCASE_P3_TELEPROMPTER_PNG"] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let view = panel.contentView else { return }
                // The display link does not run while the screen is locked: the script is where its spring goes.
                if isFollowing {
                    follow = SpringValue(value: followTarget, spring: Motion.timelineScroll)
                    model.move(to: followTarget)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                Self.writePNG(of: view, to: URL(filePath: path))
            }
        }
    }

    /// `view` drawn into a PNG at `url`, over a dark background (the glass is the window server's).
    private static func writePNG(of view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.12, alpha: 1).setFill()
        view.bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.displayIgnoringOpacity(view.bounds, in: context) }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif
}

/// What the teleprompter's SwiftUI content shows; `TeleprompterPanel` keeps it up to date.
@MainActor @Observable
private final class TeleprompterModel {
    var scroll = TeleprompterScroll()
    var isEditing = false
    var reduceMotion = false
    var reduceTransparency = false
    /// The script of the project a re-record records into, while the teleprompter reads it (decision 11); `nil`, the
    /// settings'.
    var projectScript: String?
    /// The script as it is read, line by line (`relayout`).
    private(set) var layout = ReaderLayout()
    /// The script as it is read, with the room before and after it (`TeleprompterView.leadIn`, `leadOut`).
    private(set) var contentHeight = 0.0

    @ObservationIgnored let setting: TeleprompterSetting
    @ObservationIgnored let voice: TeleprompterVoice
    @ObservationIgnored var beginEditing: () -> Void = {}
    @ObservationIgnored var endEditing: () -> Void = {}
    /// How far the script can go up changed.
    @ObservationIgnored var scrollLimitChanged: () -> Void = {}
    /// The project's script was edited.
    @ObservationIgnored var projectScriptChanged: () -> Void = {}

    init(setting: TeleprompterSetting, voice: TeleprompterVoice) {
        self.setting = setting
        self.voice = voice
    }

    /// The script read: the project's during a re-record of a project with one, the settings' otherwise.
    var script: String { projectScript ?? setting.value.script }

    /// Edits the script read.
    func edit(_ script: String) {
        if projectScript != nil {
            guard script != projectScript else { return }
            projectScript = script
            projectScriptChanged()
        } else {
            setting.update { $0.script = script }
        }
    }

    /// It follows the voice: what was said is dimmed.
    var isFollowing: Bool { setting.value.followsVoice && voice.note == nil }

    /// How far the script can go up: until its last line is at the bottom of the clear band.
    var maximumOffset: Double { Self.maximumOffset(contentHeight: contentHeight) }

    /// The scroll at `offset`, within the script.
    func move(to offset: Double) {
        var scroll = scroll
        scroll.move(to: offset, maximum: maximumOffset)
        if scroll != self.scroll { self.scroll = scroll }
    }

    /// Lays the script out again if it or its size changed (not while it is edited: the reader is not shown then); the
    /// scroll keeps its place in it, and a voice that follows it follows the new words from the same place.
    func relayout() {
        let script = script
        let fontSize = setting.value.fontSize
        guard script != layout.script || fontSize != layout.fontSize else { return }
        let wordsChanged = script != layout.script
        layout = ReaderLayout(script: script, fontSize: fontSize, width: TeleprompterView.textWidth)
        if wordsChanged { voice.restart(script: layout.words, at: min(voice.place.word, layout.words.words.count)) }
        contentHeightChanged(to: script.isEmpty ? 0 : TeleprompterView.leadIn + layout.lines.height + TeleprompterView.leadOut)
    }

    /// The script was laid out again (another size, or edited): the scroll keeps its place in it.
    private func contentHeightChanged(to height: Double) {
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

    /// Why Follow the Voice, on, does not follow.
    var note: TeleprompterFollow.Note? { setting.value.followsVoice ? voice.note : nil }
}

/// The script laid out for the reader: its words, its lines, and the text of each.
private struct ReaderLayout {
    var script = ""
    var fontSize = 0.0
    var words = ScriptWords("")
    var lines = TeleprompterLines(script: "", words: ScriptWords(""), fontSize: 22, width: 0)
    /// What each line draws.
    var texts: [String] = []

    init() {}

    /// `script` at `fontSize` in lines `width` wide.
    init(script: String, fontSize: Double, width: Double) {
        self.script = script
        self.fontSize = fontSize
        words = ScriptWords(script)
        lines = TeleprompterLines(script: script, words: words, fontSize: fontSize, width: width)
        let utf16 = script.utf16
        texts = lines.lines.map { line in
            let start = utf16.index(utf16.startIndex, offsetBy: line.characters.lowerBound)
            let end = utf16.index(start, offsetBy: line.characters.count)
            return String(script[start..<end])
        }
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
    /// Between the script and the panel's sides.
    static let sideInset = 28.0
    /// How wide the script's lines are.
    static let textWidth = TeleprompterLayout.width - 2 * sideInset
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

/// The script as it is read: centered, semibold, at the chosen size and opacity (35 % at least), each line of
/// `TeleprompterLines` where it was measured, moved up by the scroll; following the voice, what was said at 40 % of the
/// text's opacity. Without a script it says "Write your script…", and a click on it edits it. While Follow the Voice is
/// on and cannot follow, its note says why, at the top.
private struct ScriptReader: View {
    let model: TeleprompterModel

    var body: some View {
        let settings = model.setting.value
        let isEmpty = model.script.isEmpty
        ZStack(alignment: .top) {
            if isEmpty {
                Text("Write your script…")
                    .opacity(0.45)
                    .font(.system(size: settings.fontSize, weight: .semibold))
                    .tracking(TeleprompterLines.trackingShare * settings.fontSize)
                    .multilineTextAlignment(.center)
                    .frame(width: TeleprompterView.textWidth)
                    .padding(.top, TeleprompterView.leadIn)
            } else {
                lines(fontSize: settings.fontSize)
            }
        }
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
        .overlay(alignment: .top) {
            if let note = model.note {
                FollowNote(note: note)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(model.reduceMotion ? nil : .easeOut(duration: Motion.contentExit.timeInterval), value: model.note)
    }

    /// The lines seen in the reading area, each at its place.
    @ViewBuilder
    private func lines(fontSize: Double) -> some View {
        let layout = model.layout
        let offset = model.scroll.offset
        let spoken = model.isFollowing ? spokenEnd(layout: layout, word: model.voice.place.word) : 0
        ForEach(visibleLines(layout: layout, offset: offset), id: \.self) { index in
            let line = layout.lines.lines[index]
            Text(Self.text(layout.texts[index], from: line.characters.lowerBound, spokenUpTo: spoken))
                .font(.system(size: fontSize, weight: .semibold))
                .tracking(TeleprompterLines.trackingShare * fontSize)
                .lineLimit(1)
                // A word wider than the line is drawn smaller rather than cut.
                .minimumScaleFactor(0.25)
                .frame(width: TeleprompterView.textWidth, height: line.height)
                .offset(y: TeleprompterView.leadIn + line.top - offset)
        }
    }

    /// The lines between the top and the bottom of the reading area.
    private func visibleLines(layout: ReaderLayout, offset: Double) -> [Int] {
        let top = offset - TeleprompterView.leadIn
        let bottom = top + TeleprompterView.readingHeight
        guard let first = layout.lines.line(at: top) else { return [] }
        var indices: [Int] = []
        var index = first
        while index < layout.lines.lines.count, layout.lines.lines[index].top < bottom {
            indices.append(index)
            index += 1
        }
        return indices
    }

    /// The UTF-16 offset in the script where what is not said yet starts: the next word to say.
    private func spokenEnd(layout: ReaderLayout, word: Int) -> Int {
        word < layout.words.words.count ? layout.words.words[word].characters.lowerBound : layout.script.utf16.count
    }

    /// `text` (of the script, from UTF-16 offset `start`), its characters before `spoken` dimmed.
    private static func text(_ text: String, from start: Int, spokenUpTo spoken: Int) -> AttributedString {
        var attributed = AttributedString(text)
        let count = min(max(spoken - start, 0), text.utf16.count)
        guard count > 0 else { return attributed }
        let end = String.Index(utf16Offset: count, in: text)
        if let range = Range(text.startIndex..<end, in: attributed) {
            attributed[range].foregroundColor = Color.white.opacity(TeleprompterFollow.spokenOpacity)
        }
        return attributed
    }
}

/// Why Follow the Voice does not follow, in a quiet capsule over the top of the script.
private struct FollowNote: View {
    let note: TeleprompterFollow.Note

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: "waveform.and.mic").symbolRenderingMode(.hierarchical)
        }
        .labelStyle(TightLabelStyle())
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.4)))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    private var text: Text {
        switch note {
        case .needsMacOS26:
            Text("Follow the Voice needs macOS 26.", comment: "The teleprompter, with Follow the Voice on, on macOS 15")
        case .missingLanguage(let language):
            Text(
                "The “\(Locale.current.localizedString(forIdentifier: language) ?? language)” language is missing on this Mac: download it in Captions.",
                comment: "The teleprompter, with Follow the Voice on: the speech model of that language is not on the Mac")
        case .noMicrophone:
            Text("The take doesn't record the microphone.", comment: "The teleprompter, with Follow the Voice on, in a take without a microphone")
        case .failed:
            Text("Couldn't follow the voice.", comment: "The teleprompter, with Follow the Voice on: the live transcription failed")
        }
    }
}

/// The script in a text field, which has the keyboard while it shows.
private struct ScriptEditor: View {
    let model: TeleprompterModel
    @FocusState private var isFocused: Bool

    var body: some View {
        let script = Binding(get: { model.script }, set: { script in model.edit(script) })
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

/// Edit or Done and the text size on the left; Follow the Voice, the speed (off while it follows) and the opacity with
/// their values in the middle; and "Not in the video", a quiet note rather than a control, on the right. Every change is
/// saved.
private struct TeleprompterControls: View {
    let model: TeleprompterModel

    var body: some View {
        let setting = model.setting
        let settings = setting.value
        // Room for each title whole in Spanish too, with Follow the Voice.
        HStack(spacing: 8) {
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
            FollowVoiceSwitch(isOn: settings.followsVoice) { setting.update { $0.followsVoice.toggle() } }
            SliderControl(
                symbol: "gauge.with.dots.needle.33percent", title: Text("Speed"),
                value: Binding(get: { settings.speed }, set: { speed in setting.update { $0.speed = speed } }),
                range: TeleprompterSettings.speeds, step: 0.1,
                valueText: (settings.speed.formatted(.number.precision(.fractionLength(1)))) + "×")
            // While it follows the voice, the speed does nothing.
            .disabled(model.isFollowing)
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

/// "Follow the Voice": a round switch with its symbol, lit while it is on; its title is its help and what VoiceOver
/// reads.
private struct FollowVoiceSwitch: View {
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "waveform.and.mic")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(GlassButtonStyle(shape: .circle, isOn: isOn))
        .help(Text("Follow the Voice"))
        .accessibilityLabel(Text("Follow the Voice"))
        .accessibilityAddTraits(isOn ? [.isToggle, .isSelected] : .isToggle)
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
    @Environment(\.isEnabled) private var isEnabled

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
                .frame(width: 64)
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
        .opacity(isEnabled ? 1 : 0.4)
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
