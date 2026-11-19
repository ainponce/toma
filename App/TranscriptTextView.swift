// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import SwiftUI

/// What the transcript's text does with the words, done by the Captions tab. Words are indices of `TranscriptText.words`.
struct TranscriptTextActions {
    /// A word was clicked: the playhead goes to it.
    var seek: (Int) -> Void
    /// ⌫, ⌦, Cut: the words are cut out of the video.
    var cut: (ClosedRange<Int>) -> Void
    /// Restore: the cut words among them are given back.
    var restore: (ClosedRange<Int>) -> Void
    /// The word's text, corrected.
    var correct: (Int, String) -> Void
    /// Start a Caption Here, on or off.
    var toggleBreak: (Int) -> Void
    /// Space.
    var playPause: () -> Void
}

/// What the text marks while the pointer is over "Remove Filler Words" or "Shorten Pauses" (design §5.4): the fillers
/// tinted, or a "‖" after the word before each pause.
enum TranscriptMarks: Equatable {
    case none
    case fillers([Int])
    case pauses([Int])
}

/// What the tab asks the text to do once.
enum TranscriptTextRequest: Equatable {
    /// Select the word and show it (the timeline's caption double-clicked, `EditorVoice.revealed`).
    case reveal(Int)
    /// Edit the word in its field.
    case edit(Int)
}

/// The Captions tab's Text (design §5.3): the transcript as running text in an `NSTextView` of TextKit 1, read only,
/// whose attributes are made again only when the text changes (the cut words struck through and dimmed); the word being
/// said, the marks of the buttons and the caption breaks are drawn under the glyphs, so playing never lays the text out
/// again. A selection is of whole words, whatever the mouse or the keys asked for.
///
/// - A click puts the playhead on the word; a drag or ⇧click selects words; a double click (or Return on one word)
///   edits the word in a field over it; ⌫ and ⌦ cut the words selected; Space plays and pauses; ← and → select the word
///   before or after (⇧ extends the selection); Esc selects nothing. The context menu has Cut, Restore, Correct the
///   Word… and Start a Caption Here, and VoiceOver has them as actions.
/// - While it plays, the text follows the word being said, gliding with `Motion.timelineScroll` (a jump with Reduce
///   Motion); scrolling it by hand stops that until the word being said is in view again, playing starts again or the
///   playhead is moved while paused.
struct TranscriptTextView: NSViewRepresentable {
    let text: TranscriptText
    /// The word being said, an index of `text.words`.
    let playing: Int?
    let isPlaying: Bool
    let marks: TranscriptMarks
    /// Whether the words can be cut, restored and corrected (the project can be edited).
    let canEdit: Bool
    @Binding var selection: ClosedRange<Int>?
    @Binding var request: TranscriptTextRequest?
    let actions: TranscriptTextActions
    /// The height of the visible part of the panel's scroll view the text is in, as it changes: what the tab sizes the
    /// text by.
    var panelHeight: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TranscriptScrollView {
        // TextKit 1: its temporary attributes and glyph geometry draw and hit the words without laying the text out again.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = TranscriptNSTextView(frame: .zero, textContainer: container)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        let scrollView = TranscriptScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.findBarPosition = .aboveContent
        scrollView.onUserScroll = { [weak coordinator = context.coordinator] in coordinator?.userScrolled() }
        scrollView.onResize = { [weak coordinator = context.coordinator] in coordinator?.resized() }
        scrollView.onPanelHeight = { [weak coordinator = context.coordinator] height in
            // Not while SwiftUI lays the view out.
            DispatchQueue.main.async { coordinator?.parent.panelHeight(height) }
        }
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.autoresizingMask = NSView.AutoresizingMask.width
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: TranscriptScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranscriptTextView
        fileprivate weak var textView: TranscriptNSTextView?
        fileprivate weak var scrollView: TranscriptScrollView?
        /// The text the storage has.
        private var shown: TranscriptText?
        /// Whether the text follows the word being said.
        private var following = true
        private var lastPlaying: Int?
        private var wasPlaying = false
        /// The selection is being set from the tab: its change is not sent back.
        private var settingSelection = false

        init(parent: TranscriptTextView) {
            self.parent = parent
        }

        fileprivate func update(_ parent: TranscriptTextView) {
            self.parent = parent
            guard let textView, let scrollView else { return }
            textView.canEdit = parent.canEdit
            if shown != parent.text {
                textView.show(parent.text, replacing: shown)
                shown = parent.text
            }
            textView.marks = parent.marks
            if textView.selectedWords != parent.selection {
                settingSelection = true
                textView.selectWords(parent.selection)
                settingSelection = false
            }
            textView.playing = parent.playing
            let started = parent.isPlaying && !wasPlaying
            wasPlaying = parent.isPlaying
            if started { following = true }
            if let playing = parent.playing, playing != lastPlaying || started {
                if !parent.isPlaying {
                    // The playhead moved while paused (a click on the timeline, a key): the text goes to it.
                    following = true
                } else if !following, textView.isVisible(word: playing, in: scrollView) {
                    following = true
                }
                if following { textView.follow(word: playing, in: scrollView, glide: lastPlaying != nil) }
            }
            lastPlaying = parent.playing
            if let request = parent.request {
                // Once each: the tab takes it back on the next turn.
                if request != seen {
                    seen = request
                    pending = request
                    DispatchQueue.main.async { [weak self] in
                        if self?.parent.request == request { self?.parent.request = nil }
                    }
                }
            } else {
                seen = nil
            }
            carryOutPending()
        }

        /// The tab's request seen last, until the tab takes it back.
        private var seen: TranscriptTextRequest?
        /// The request of the tab not carried out yet: it waits until the text is laid out at its width.
        private var pending: TranscriptTextRequest?

        private func carryOutPending() {
            guard let request = pending, let textView, let scrollView, textView.isLaidOut(in: scrollView) else { return }
            pending = nil
            switch request {
            case .reveal(let word):
                textView.selectWords(word...word)
                textView.reveal(word: word, in: scrollView)
            case .edit(let word):
                textView.beginEditing(word)
            }
        }

        /// The text was scrolled by hand: it stops following the word being said.
        fileprivate func userScrolled() {
            following = false
        }

        /// The text has another width, so other lines: the word being said is followed again where it is now.
        fileprivate func resized() {
            guard let textView, let scrollView else { return }
            // The field of a word being corrected is over where the word was.
            textView.endEditing(commit: true)
            if following, let playing = lastPlaying { textView.follow(word: playing, in: scrollView, glide: false) }
            carryOutPending()
        }

        // MARK: - What the text view says

        fileprivate var actions: TranscriptTextActions { parent.actions }

        /// The selection snaps to whole words; one of spaces only is none.
        func textView(
            _ textView: NSTextView, willChangeSelectionFromCharacterRanges old: [NSValue], toCharacterRanges new: [NSValue]
        ) -> [NSValue] {
            guard let text = (textView as? TranscriptNSTextView)?.transcript, !new.isEmpty else { return new }
            let ranges = new.map(\.rangeValue)
            let low = ranges.map(\.location).min() ?? 0
            let high = ranges.map { NSMaxRange($0) }.max() ?? low
            guard let words = text.words(inCharacters: low..<high) else { return [NSValue(range: NSRange(location: low, length: 0))] }
            let characters = text.characters(of: words)
            return [NSValue(range: NSRange(location: characters.lowerBound, length: characters.count))]
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !settingSelection, let textView else { return }
            let words = textView.selectedWords
            guard words != parent.selection else { return }
            // Not while SwiftUI updates the view: the next turn of the run loop.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textView?.selectedWords == words, self.parent.selection != words else { return }
                self.parent.selection = words
            }
        }
    }
}

// MARK: - The scroll view

/// The scroll view of the text: it says when it is scrolled by hand, and glides to a place with a spring, which a
/// scroll by hand stops.
final class TranscriptScrollView: NSScrollView {
    var onUserScroll: () -> Void = {}
    /// Its width changed.
    var onResize: () -> Void = {}
    /// The visible height of the scroll view it is in (the panel's), when it changes.
    var onPanelHeight: (CGFloat) -> Void = { _ in }
    private weak var outer: NSScrollView?
    private var reportedHeight: CGFloat = -1
    private var glideY: SpringValue?
    private var lastTick: CFTimeInterval?
    /// While it glides; it holds the view until it settles.
    private var link: CADisplayLink?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A drag of the scroller (removed by the system when the view goes).
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolledByHand), name: NSScrollView.willStartLiveScrollNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let outer { NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: outer) }
        outer = superview?.enclosingScrollView
        guard let outer else { return }
        outer.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(outerChanged), name: NSView.frameDidChangeNotification, object: outer)
        outerChanged()
    }

    @objc private func outerChanged() {
        guard let outer else { return }
        let height = outer.contentView.bounds.height
        guard abs(height - reportedHeight) > 0.5 else { return }
        reportedHeight = height
        onPanelHeight(height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { onResize() }
    }

    override func scrollWheel(with event: NSEvent) {
        scrolledByHand()
        super.scrollWheel(with: event)
    }

    @objc private func scrolledByHand() {
        stopGliding()
        onUserScroll()
    }

    /// Scrolls so the document's `y` is at the top: gliding with `Motion.timelineScroll` from where it is (and at the
    /// speed it has, if it was gliding already), or at once.
    func scroll(toY y: CGFloat, glide: Bool) {
        let visible = contentView.bounds
        let top = max(0, min(y, (documentView?.frame.height ?? 0) - visible.height))
        guard glide, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopGliding()
            contentView.scroll(to: NSPoint(x: visible.minX, y: top))
            reflectScrolledClipView(contentView)
            return
        }
        var spring = glideY ?? SpringValue(value: Double(visible.minY), spring: Motion.timelineScroll)
        spring.retarget(Double(top), spring: Motion.timelineScroll)
        glideY = spring
        if link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            lastTick = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard var spring = glideY else { return stopGliding() }
        let now = link.timestamp
        let elapsed = lastTick.map { min(now - $0, 1.0 / 20) } ?? 1.0 / 120
        lastTick = now
        spring.step(by: elapsed)
        glideY = spring
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: CGFloat(spring.value)))
        reflectScrolledClipView(contentView)
        if spring.isSettled { stopGliding() }
    }

    private func stopGliding() {
        link?.invalidate()
        link = nil
        glideY = nil
        lastTick = nil
    }
}

// MARK: - The text view

/// The text view of the transcript: TextKit 1, read only, selectable by whole words.
final class TranscriptNSTextView: NSTextView, NSTextFieldDelegate {
    weak var coordinator: TranscriptTextView.Coordinator?
    private(set) var transcript: TranscriptText?
    var canEdit = true {
        didSet { if !canEdit { endEditing(commit: false) } }
    }
    /// The word being said.
    var playing: Int? {
        didSet {
            guard playing != oldValue else { return }
            invalidate(word: oldValue)
            invalidate(word: playing)
        }
    }
    var marks = TranscriptMarks.none {
        didSet {
            guard marks != oldValue else { return }
            applyMarks()
        }
    }
    /// The words that start a caption.
    private var breaks: [Int] = []
    private var editor: NSTextField?
    private var editingWord: Int?

    static let font = NSFont.systemFont(ofSize: 14)
    private static let lineHeight: CGFloat = 22
    /// The empty line between two paragraphs.
    private static let paragraphGap: CGFloat = 9

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func setUp() {
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = false
        drawsBackground = false
        isContinuousSpellCheckingEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        textContainerInset = NSSize(width: 6, height: 10)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager?.allowsNonContiguousLayout = true
        selectedTextAttributes = [.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.32)]
        font = Self.font
        setAccessibilityLabel(String(localized: "Transcript", comment: "VoiceOver: the Captions tab's text of the words spoken"))
        setAccessibilityHelp(
            String(
                localized: "Select words and press Delete to cut them from the video.",
                comment: "The Captions tab, under its text: how to cut words"))
    }

    // MARK: - The text

    /// Shows `text`: the string and its attributes made again if its string is not `previous`'s; otherwise only the
    /// attributes of the words whose cut changed. The selection keeps its words.
    func show(_ text: TranscriptText, replacing previous: TranscriptText?) {
        guard let storage = textStorage else { return }
        endEditing(commit: false)
        let selected = selectedWords
        storage.beginEditing()
        if let previous, previous.string == text.string, previous.words.count == text.words.count {
            for (old, new) in zip(previous.words, text.words) where old.isCut != new.isCut {
                storage.setAttributes(Self.attributes(cut: new.isCut), range: NSRange(new.characters))
            }
        } else {
            storage.setAttributedString(Self.attributed(text))
        }
        storage.endEditing()
        transcript = text
        breaks = text.words.indices.filter { text.words[$0].breakBefore }
        let words = selected.map { $0.clamped(to: 0...max(text.words.count - 1, 0)) }
        selectWords(text.words.isEmpty ? nil : words)
        applyMarks()
        needsDisplay = true
    }

    private static func attributed(_ text: TranscriptText) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text.string, attributes: attributes(cut: false))
        for word in text.words where word.isCut {
            string.setAttributes(attributes(cut: true), range: NSRange(word.characters))
        }
        // The empty line of each paragraph's break is shorter than a line of text.
        let gap = NSMutableParagraphStyle()
        gap.minimumLineHeight = paragraphGap
        gap.maximumLineHeight = paragraphGap
        let utf16 = text.string.utf16
        var previous: Int?
        for word in text.words {
            if let previous, word.characters.lowerBound - previous == 2,
                utf16[utf16.index(utf16.startIndex, offsetBy: previous)] == 0x0A
            {
                string.addAttribute(.paragraphStyle, value: gap, range: NSRange(location: previous + 1, length: 1))
            }
            previous = word.characters.upperBound
        }
        return string
    }

    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    private static func attributes(cut: Bool) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        if cut {
            attributes[.foregroundColor] = NSColor.tertiaryLabelColor
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = NSColor.secondaryLabelColor
        } else {
            attributes[.foregroundColor] = NSColor.labelColor
        }
        return attributes
    }

    /// The fillers' tint while their button is under the pointer.
    private func applyMarks() {
        guard let layoutManager, let transcript else { return }
        let whole = NSRange(location: 0, length: (transcript.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        if case .fillers(let words) = marks {
            for word in words where transcript.words.indices.contains(word) {
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: NSColor.controlAccentColor, forCharacterRange: NSRange(transcript.words[word].characters))
            }
        }
        needsDisplay = true
    }

    // MARK: - Selection

    /// The words selected; `nil` for none.
    var selectedWords: ClosedRange<Int>? {
        let range = selectedRange()
        guard range.length > 0, let transcript else { return nil }
        return transcript.words(inCharacters: range.location..<NSMaxRange(range))
    }

    func selectWords(_ words: ClosedRange<Int>?) {
        guard let transcript, let words, transcript.words.indices.contains(words.lowerBound),
            transcript.words.indices.contains(words.upperBound)
        else {
            setSelectedRange(NSRange(location: min(selectedRange().location, (string as NSString).length), length: 0))
            return
        }
        let characters = transcript.characters(of: words)
        setSelectedRange(NSRange(characters))
    }

    /// The word under `point` (in the view's coordinates), its glyphs' box a little larger; `nil` between words.
    func word(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let transcript, !transcript.words.isEmpty else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard box.insetBy(dx: -2, dy: -3).contains(inContainer) else { return nil }
        return transcript.wordIndex(atCharacter: layoutManager.characterIndexForGlyph(at: glyph))
    }

    // MARK: - Mouse and keys

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = word(at: point)
        if event.clickCount == 2, let clicked, canEdit {
            beginEditing(clicked)
            return
        }
        endEditing(commit: true)
        let start = event.locationInWindow
        // Tracks the drag until the mouse goes up; the delegate snaps the selection to words.
        super.mouseDown(with: event)
        guard event.clickCount == 1, !event.modifierFlags.contains(.shift), let clicked, let window else { return }
        let end = window.mouseLocationOutsideOfEventStream
        guard hypot(end.x - start.x, end.y - start.y) < 4 else { return }
        selectWords(clicked...clicked)
        coordinator?.actions.seek(clicked)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        endEditing(commit: true)
        let point = convert(event.locationInWindow, from: nil)
        if let clicked = word(at: point), !(selectedWords?.contains(clicked) ?? false) { selectWords(clicked...clicked) }
        guard let words = selectedWords, let transcript else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool, on: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled && canEdit
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        add(String(localized: "Cut", comment: "The Captions tab's context menu: cut the selected words out of the video"),
            #selector(cutSelected(_:)), enabled: transcript.hasKept(words))
        add(String(localized: "Restore"), #selector(restoreSelected(_:)), enabled: transcript.hasCut(words))
        menu.addItem(.separator())
        let single = words.lowerBound == words.upperBound
        add(String(localized: "Correct the Word…", comment: "The Captions tab's context menu: edit the text of a word"),
            #selector(correctSelected(_:)), enabled: single)
        add(String(localized: "Start a Caption Here"), #selector(toggleBreakSelected(_:)), enabled: single,
            on: single && transcript.words[words.lowerBound].breakBefore)
        return menu
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "f" {
            // ⌘F: the find bar over the text (the app's menus have no Find).
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            performTextFinderAction(item)
            return
        }
        switch (event.keyCode, flags) {
        case (49, []):  // Space
            coordinator?.actions.playPause()
        case (51, []), (117, []):  // ⌫, ⌦
            cutSelected(nil)
        case (53, []):  // Esc
            selectWords(nil)
        case (36, []), (76, []):  // Return, Enter
            if let words = selectedWords, words.lowerBound == words.upperBound, canEdit {
                beginEditing(words.lowerBound)
            } else {
                NSSound.beep()
            }
        case (123, []), (124, []):  // ← →
            step(forward: event.keyCode == 124, extending: false)
        case (123, [.shift]), (124, [.shift]):
            step(forward: event.keyCode == 124, extending: true)
        default:
            super.keyDown(with: event)
        }
    }

    /// ← and →: the word before or after the selection (the word being said, without one), with the playhead on it;
    /// with ⇧, the selection grows by a word that way.
    private func step(forward: Bool, extending: Bool) {
        guard let transcript, !transcript.words.isEmpty else { return }
        let last = transcript.words.count - 1
        guard let words = selectedWords else {
            let word = playing ?? (forward ? 0 : last)
            selectWords(word...word)
            coordinator?.actions.seek(word)
            return
        }
        if extending {
            let grown = forward ? words.lowerBound...min(words.upperBound + 1, last) : max(words.lowerBound - 1, 0)...words.upperBound
            selectWords(grown)
            return
        }
        let word = forward ? min(words.upperBound + 1, last) : max(words.lowerBound - 1, 0)
        selectWords(word...word)
        scrollRangeToVisible(NSRange(transcript.words[word].characters))
        coordinator?.actions.seek(word)
    }

    @objc private func cutSelected(_ sender: Any?) {
        guard canEdit, let words = selectedWords, transcript?.hasKept(words) == true else { return NSSound.beep() }
        coordinator?.actions.cut(words)
    }

    @objc private func restoreSelected(_ sender: Any?) {
        guard canEdit, let words = selectedWords, transcript?.hasCut(words) == true else { return NSSound.beep() }
        coordinator?.actions.restore(words)
    }

    @objc private func correctSelected(_ sender: Any?) {
        guard let words = selectedWords, words.lowerBound == words.upperBound else { return }
        beginEditing(words.lowerBound)
    }

    @objc private func toggleBreakSelected(_ sender: Any?) {
        guard canEdit, let words = selectedWords, words.lowerBound == words.upperBound else { return }
        coordinator?.actions.toggleBreak(words.lowerBound)
    }

    // MARK: - VoiceOver

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard canEdit, let words = selectedWords, let transcript else { return nil }
        var actions: [NSAccessibilityCustomAction] = []
        if transcript.hasKept(words) {
            actions.append(NSAccessibilityCustomAction(name: String(localized: "Cut")) { [weak self] in
                self?.cutSelected(nil)
                return true
            })
        }
        if transcript.hasCut(words) {
            actions.append(NSAccessibilityCustomAction(name: String(localized: "Restore")) { [weak self] in
                self?.restoreSelected(nil)
                return true
            })
        }
        if words.lowerBound == words.upperBound {
            actions.append(NSAccessibilityCustomAction(name: String(localized: "Correct the Word…")) { [weak self] in
                self?.correctSelected(nil)
                return true
            })
            actions.append(NSAccessibilityCustomAction(name: String(localized: "Start a Caption Here")) { [weak self] in
                self?.toggleBreakSelected(nil)
                return true
            })
        }
        return actions
    }

    // MARK: - Correcting a word

    /// Edits the word `word` in a field over it: Return or leaving it corrects the word, Esc leaves it as it was.
    func beginEditing(_ word: Int) {
        guard canEdit, let transcript, transcript.words.indices.contains(word) else { return }
        endEditing(commit: false)
        selectWords(word...word)
        let characters = NSRange(transcript.words[word].characters)
        scrollRangeToVisible(characters)
        guard let box = rects(forCharacters: characters).first else { return }
        let current = (transcript.string as NSString).substring(with: characters)
        let field = NSTextField(string: current)
        field.font = Self.font
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(String(localized: "Word", comment: "VoiceOver: the field that corrects a word of the Captions tab"))
        let height = field.intrinsicContentSize.height
        let width = min(max(box.width + 36, 96), max(bounds.width - 8, 96))
        let x = min(max(box.minX - 8, 4), max(bounds.width - width - 4, 4))
        field.frame = NSRect(x: x, y: box.midY - height / 2, width: width, height: height)
        addSubview(field)
        editor = field
        editingWord = word
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// The field goes away, correcting the word with what it has if `commit`.
    func endEditing(commit: Bool) {
        guard let field = editor, let word = editingWord else { return }
        editor = nil
        editingWord = nil
        let text = field.stringValue
        let hadFocus = window?.firstResponder === field.currentEditor()
        field.removeFromSuperview()
        if hadFocus { window?.makeFirstResponder(self) }
        if commit { coordinator?.actions.correct(word, text) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(commit: false)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            endEditing(commit: true)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endEditing(commit: true)
    }

    // MARK: - Following

    /// Whether the text has its width and the scroll view its height: the places of the words are where they stay.
    func isLaidOut(in scrollView: NSScrollView) -> Bool {
        bounds.width > 60 && scrollView.contentView.bounds.height > 40
    }

    /// Whether the word `word` is in the visible part of the text.
    func isVisible(word: Int, in scrollView: NSScrollView) -> Bool {
        guard let transcript, transcript.words.indices.contains(word),
            let box = rects(forCharacters: NSRange(transcript.words[word].characters)).first
        else { return false }
        return scrollView.contentView.bounds.contains(box)
    }

    /// The word `word` is kept away from the edges of the visible part: if it is out of its middle band, the text glides
    /// (or jumps) so it is a third of the way down.
    func follow(word: Int, in scrollView: TranscriptScrollView, glide: Bool) {
        // Not laid out at its width yet: every word would be on a line of its own.
        guard isLaidOut(in: scrollView), let transcript, transcript.words.indices.contains(word),
            let box = rects(forCharacters: NSRange(transcript.words[word].characters)).first
        else { return }
        let visible = scrollView.contentView.bounds
        let band = visible.insetBy(dx: 0, dy: min(visible.height * 0.18, 60))
        guard !band.contains(box) else { return }
        scrollView.scroll(toY: box.minY - visible.height / 3, glide: glide)
    }

    /// The word `word` in the middle of the visible part.
    func reveal(word: Int, in scrollView: TranscriptScrollView) {
        guard let transcript, transcript.words.indices.contains(word),
            let box = rects(forCharacters: NSRange(transcript.words[word].characters)).first
        else { return }
        let visible = scrollView.contentView.bounds
        guard !visible.insetBy(dx: 0, dy: 24).contains(box) else { return }
        scrollView.scroll(toY: box.midY - visible.height / 2, glide: true)
    }

    // MARK: - Drawing

    /// The boxes of the glyphs of `characters`, one per line, around each line's baseline as tall as the font, in the
    /// view's coordinates.
    func rects(forCharacters characters: NSRange) -> [NSRect] {
        guard let layoutManager, characters.length > 0 else { return [] }
        let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        let font = Self.font
        var rects: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, container, lineGlyphs, _ in
            let part = NSIntersectionRange(glyphs, lineGlyphs)
            guard part.length > 0 else { return }
            var box = layoutManager.boundingRect(forGlyphRange: part, in: container)
            let baseline = line.minY + layoutManager.location(forGlyphAt: part.location).y
            box.origin.y = baseline - font.ascender
            box.size.height = font.ascender - font.descender
            rects.append(box.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
        }
        return rects
    }

    private func invalidate(word: Int?) {
        guard let word, let transcript, transcript.words.indices.contains(word) else { return }
        for box in rects(forCharacters: NSRange(transcript.words[word].characters)) {
            setNeedsDisplay(box.insetBy(dx: -6, dy: -4))
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let transcript, let layoutManager, let textContainer, !transcript.words.isEmpty else { return }
        // Only the words in `rect`.
        let inContainer = rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: inContainer, in: textContainer)
        let shown = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        func onScreen(_ word: Int) -> Bool {
            NSIntersectionRange(NSRange(transcript.words[word].characters), shown).length > 0
                || NSLocationInRange(transcript.words[word].characters.upperBound, shown)
        }
        let accent = NSColor.controlAccentColor
        switch marks {
        case .fillers(let words):
            accent.withAlphaComponent(0.16).setFill()
            for word in words where transcript.words.indices.contains(word) && onScreen(word) {
                for box in rects(forCharacters: NSRange(transcript.words[word].characters)) {
                    NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -1), xRadius: 4, yRadius: 4).fill()
                }
            }
        case .pauses(let words):
            for word in words where transcript.words.indices.contains(word) && onScreen(word) {
                drawPauseMark(after: word, in: transcript, color: accent)
            }
        case .none:
            break
        }
        // A short bar before each word a caption starts at.
        accent.withAlphaComponent(0.85).setFill()
        for word in breaks where onScreen(word) {
            guard let box = rects(forCharacters: NSRange(transcript.words[word].characters)).first else { continue }
            NSBezierPath(roundedRect: NSRect(x: box.minX - 4, y: box.minY + 2, width: 2, height: box.height - 4), xRadius: 1, yRadius: 1).fill()
        }
        if let playing, transcript.words.indices.contains(playing), onScreen(playing) {
            accent.withAlphaComponent(0.25).setFill()
            for box in rects(forCharacters: NSRange(transcript.words[playing].characters)) {
                NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -1), xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    /// "‖" in the space after the word `word`, or just after it at the end of a paragraph.
    private func drawPauseMark(after word: Int, in transcript: TranscriptText, color: NSColor) {
        guard let box = rects(forCharacters: NSRange(transcript.words[word].characters)).last else { return }
        let mark = NSAttributedString(
            string: "‖", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: color])
        let size = mark.size()
        var x = box.maxX + 1
        let next = word + 1
        if next < transcript.words.count,
            let following = rects(forCharacters: NSRange(transcript.words[next].characters)).first,
            abs(following.midY - box.midY) < 1, following.minX > box.maxX
        {
            x = (box.maxX + following.minX - size.width) / 2
        }
        color.withAlphaComponent(0.16).setFill()
        let pill = NSRect(x: x - 2, y: box.minY, width: size.width + 4, height: box.height)
        NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
        mark.draw(at: NSPoint(x: x, y: box.midY - size.height / 2))
    }
}
