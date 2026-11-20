// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat

/// The header of a track (design §5.5): its icon and name, and on an audio track the Mute button under the name, both
/// lines centered in the row as one block. A name wider than its line (Spanish's "Anotaciones", "Clips importados") goes
/// to two lines in a row tall enough for them when it has two words, and to the condensed width of the font otherwise.
final class TrackHeaderView: NSView {
    let track: TimelineTrack
    var onMute: (Bool) -> Void = { _ in }
    /// A click on the header (the Camera's: the project's layout is selected).
    var onPress: () -> Void = {}
    /// The second line of the Camera's header: the project's layout.
    private let subtitle = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private var mute: NSButton?
    private let separator = CALayer()
    /// The lines the name takes: 1, or 2 for a name of two words wider than its line, in a row that wraps.
    private var nameLines = 1

    init(track: TimelineTrack, take: TakeRecord?) {
        self.track = track
        super.init(frame: .zero)
        wantsLayer = true
        let (title, symbol) = Self.titleAndSymbol(track, take: take)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        // VoiceOver reads the name.
        icon.setAccessibilityElement(false)
        name.stringValue = title
        let fit = Self.nameFit(title, wraps: Self.wraps(track))
        name.font = fit.font
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        if fit.lines > 1 {
            name.lineBreakMode = .byWordWrapping
            name.maximumNumberOfLines = fit.lines
        }
        nameLines = fit.lines
        addSubview(icon)
        addSubview(name)
        if case .audio = track {
            let button = NSButton(
                image: NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)!, target: self,
                action: #selector(muteClicked(_:)))
            button.setButtonType(.pushOnPushOff)
            button.alternateImage = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = String(localized: "Mute")
            button.setAccessibilityLabel(String(localized: "Mute"))
            addSubview(button)
            mute = button
        }
        if case .camera = track {
            subtitle.font = .systemFont(ofSize: 10)
            subtitle.textColor = .tertiaryLabelColor
            subtitle.lineBreakMode = .byTruncatingTail
            addSubview(subtitle)
            setAccessibilityRole(.button)
            setAccessibilityLabel(String(localized: "Camera"))
        }
        layer?.addSublayer(separator)
    }

    /// The project's layout under "Camera"; with it, the header is a button.
    func setSubtitle(_ text: String?) {
        guard case .camera = track else { return }
        subtitle.stringValue = text ?? ""
        setAccessibilityValue(text)
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        if case .camera = track { onPress() } else { super.mouseDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard case .camera = track else { return false }
        onPress()
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        separator.backgroundColor = NSColor.separatorColor.cgColor
    }

    func setMuted(_ muted: Bool, enabled: Bool) {
        mute?.state = muted ? .on : .off
        mute?.isEnabled = enabled
    }

    @objc private func muteClicked(_ sender: NSButton) {
        onMute(sender.state == .on)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        // An audio track has its name on top and Mute under it; the others, the name in the middle.
        let two = track == .camera && !subtitle.stringValue.isEmpty
        let wrapped = nameLines > 1
        let line = (mute != nil ? (height - 31) / 2 : two ? (height - 27) / 2 : wrapped ? (height - 28) / 2 : (height - 14) / 2).rounded()
        icon.frame = CGRect(x: 8, y: line, width: 14, height: 14)
        // To 1 pt from the separator: "Privacidad" fits whole.
        name.frame = CGRect(x: 26, y: line, width: bounds.width - 27, height: wrapped ? 28 : 14)
        subtitle.frame = CGRect(x: 26, y: line + 14, width: bounds.width - 30, height: 13)
        // Its symbol's left edge under the name's first letter.
        mute?.frame = CGRect(x: 25, y: line + 16, width: 18, height: 15)
        separator.frame = CGRect(x: 0, y: height - 1, width: bounds.width, height: 1)
    }

    /// The width the name's text has: its field's, from the name's left to 1 pt from the separator, inside the field's
    /// insets of 2 pt.
    private static let nameWidth = TimelineLayout.headerWidth - 27 - 4

    /// Whether the name may take two lines: in the rows of phase 3 without a button under it, 36 pt tall.
    private static func wraps(_ track: TimelineTrack) -> Bool {
        switch track {
        case .importedAudio, .music: true
        default: false
        }
    }

    /// The font and lines of `title`, always 11 pt: on one line when it fits; else on two (`wraps`) when it has two words
    /// that each fit; else the same in the system font's condensed width, cut if even that does not fit. The names of
    /// phases 1 and 2 all fit on one line ("Privacidad" by 2 pt).
    private static func nameFit(_ title: String, wraps: Bool) -> (font: NSFont, lines: Int) {
        let words = title.split(separator: " ").map(String.init)
        for font in [NSFont.systemFont(ofSize: 11), .systemFont(ofSize: 11, weight: .regular, width: .condensed)] {
            func fits(_ text: String) -> Bool {
                ceil((text as NSString).size(withAttributes: [.font: font]).width) <= nameWidth
            }
            if fits(title) { return (font, 1) }
            if wraps, words.count >= 2, words.allSatisfy(fits) { return (font, 2) }
        }
        return (NSFont.systemFont(ofSize: 11, weight: .regular, width: .condensed), wraps && words.count >= 2 ? 2 : 1)
    }

    private static func titleAndSymbol(_ track: TimelineTrack, take: TakeRecord?) -> (String, String) {
        switch track {
        case .ruler: ("", "ruler")
        case .video: (String(localized: "Video"), "film")
        case .screen: (String(localized: "Screen"), "display")
        case .zoom: (String(localized: "Zoom"), "plus.magnifyingglass")
        case .captions: (String(localized: "Captions"), "captions.bubble")
        case .privacy: (String(localized: "Privacy"), "eye.slash")
        case .camera: (String(localized: "Camera"), "web.camera")
        case .annotations: (String(localized: "Annotations"), "scribble.variable")
        case .importedAudio: (String(localized: "Imported Clips", comment: "The header of the timeline's row of the sound of the imported clips"), "film")
        case .music: (String(localized: "Music"), "music.note")
        case let .audio(id):
            switch take?.track(id)?.kind {
            case .systemAudio: (String(localized: "System"), "speaker.wave.2")
            // The sound of the iPhone or iPad the take recorded, named as its frame draws it.
            case .deviceAudio:
                take.flatMap(DeviceTakeDefaults.model(of:)) == .iPad
                    ? (String(localized: "iPad", comment: "The header of the track of an iPad's sound"), "ipad")
                    : (String(localized: "iPhone", comment: "The header of the track of an iPhone's sound"), "iphone")
            default: (String(localized: "Microphone"), "mic")
            }
        }
    }
}
