// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import ProjectFormat

/// The header of a track (design §5.5): its icon and name, and on an audio track the Mute button under the name, both
/// lines centered in the row as one block.
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
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
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
        let line = (mute != nil ? (height - 31) / 2 : two ? (height - 27) / 2 : (height - 14) / 2).rounded()
        icon.frame = CGRect(x: 8, y: line, width: 14, height: 14)
        // To 1 pt from the separator: "Privacidad" fits whole.
        name.frame = CGRect(x: 26, y: line, width: bounds.width - 27, height: 14)
        subtitle.frame = CGRect(x: 26, y: line + 14, width: bounds.width - 30, height: 13)
        // Its symbol's left edge under the name's first letter.
        mute?.frame = CGRect(x: 25, y: line + 16, width: 18, height: 15)
        separator.frame = CGRect(x: 0, y: height - 1, width: bounds.width, height: 1)
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
        case let .audio(id):
            take?.track(id)?.kind == .systemAudio
                ? (String(localized: "System"), "speaker.wave.2")
                : (String(localized: "Microphone"), "mic")
        }
    }
}
