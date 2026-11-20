// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ProjectFormat

/// The text of a text or a speech bubble edited where it is drawn (phase 3 design §5.1, plan 3a Task A13): over its box
/// in the preview, as wide as it, in its font, its size (an em of `text.size` times the height of its space), its colour,
/// its alignment and its background, with its padding (a speech bubble's is a Label's), growing downwards as lines are
/// added, as the render's box does. ↩ starts a new line; ⌘↩ or a click elsewhere keeps the text, Esc gives it up, and
/// `onFinish` says which, once: the string kept (`nil` given up) and whether the view is losing the focus to another one.
final class AnnotationTextEditor: NSTextView {
    /// The text kept (`nil`: given up), and whether the focus is going to another view meanwhile.
    var onFinish: (_ string: String?, _ resigning: Bool) -> Void = { _, _ in }
    private var finished = false
    /// What holds the text and its layout, which a text view made with its own container does not keep.
    private let storage: NSTextStorage

    init(text: TextAnnotation, box: CGRect, em: Double, callout: Bool) {
        let size = CGFloat(em.isFinite && em > 0 ? em : 12)
        let preset = callout ? TextPreset.label : text.preset
        let padding = Self.padding(preset, em: size)
        let frame = CGRect(x: box.minX, y: box.minY, width: max(box.width, 2 * padding.width + size), height: box.height)
        storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: frame.width - 2 * padding.width, height: .greatestFiniteMagnitude))
        layout.addTextContainer(container)
        super.init(frame: frame, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isFieldEditor = false
        usesFindBar = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = padding
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        minSize = CGSize(width: frame.width, height: max(box.height, size + 2 * padding.height))
        maxSize = CGSize(width: frame.width, height: .greatestFiniteMagnitude)
        let color = Self.color(text.color)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch text.align {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font(text, size: size), .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        if text.fill == nil {
            // As the render draws a text without a background: the captions' shadow.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowOffset = CGSize(width: 0, height: -0.04 * size)
            shadow.shadowBlurRadius = 0.12 * size
            attributes[.shadow] = shadow
        }
        typingAttributes = attributes
        storage.setAttributedString(NSAttributedString(string: text.string, attributes: attributes))
        insertionPointColor = color
        drawsBackground = text.fill != nil
        if let fill = text.fill { backgroundColor = Self.color(fill) }
        wantsLayer = true
        layer?.cornerRadius = Self.corner(preset, callout: callout, em: size)
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        setAccessibilityLabel(String(localized: "Edit Text", comment: "VoiceOver: the text of an annotation, edited over the preview"))
        sizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        storage = container?.layoutManager?.textStorage ?? NSTextStorage()
        super.init(frame: frameRect, textContainer: container)
    }

    /// The text is kept (`keeping`) or given up, once.
    func finish(keeping: Bool) {
        finish(keeping: keeping, resigning: false)
    }

    private func finish(keeping: Bool, resigning: Bool) {
        guard !finished else { return }
        finished = true
        onFinish(keeping ? string : nil, resigning)
    }

    private static func isCommandReturn(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76)
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, Self.isCommandReturn(event) {
            finish(keeping: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.isCommandReturn(event) {
            finish(keeping: true)
            return
        }
        super.keyDown(with: event)
    }

    /// Esc.
    override func cancelOperation(_ sender: Any?) {
        finish(keeping: false)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { finish(keeping: true, resigning: true) }
        return resigned
    }

    // MARK: - The look of `annotation-1`, in points

    /// The system font in `text`'s design and weight, `size` points.
    static func font(_ text: TextAnnotation, size: CGFloat) -> NSFont {
        let weight: NSFont.Weight = switch text.weight {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign
        switch text.font {
        case .system: return base
        case .rounded: design = .rounded
        case .serif: design = .serif
        case .mono: design = .monospaced
        }
        return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    /// A Label's padding (and a speech bubble's), a Lower third's, none for the others.
    private static func padding(_ preset: TextPreset, em: CGFloat) -> CGSize {
        switch preset {
        case .plain, .title: .zero
        case .label: CGSize(width: 0.55 * em, height: 0.3 * em)
        case .lowerThird: CGSize(width: 0.8 * em, height: 0.45 * em)
        }
    }

    private static func corner(_ preset: TextPreset, callout: Bool, em: CGFloat) -> CGFloat {
        if callout { return 0.35 * em }
        return switch preset {
        case .label: 0.3 * em
        case .lowerThird: 0.12 * em
        case .plain, .title: 4
        }
    }

    private static func color(_ c: RGBA) -> NSColor {
        func unit(_ v: Double) -> CGFloat { CGFloat(v.isFinite ? min(max(v, 0), 1) : 1) }
        return NSColor(srgbRed: unit(c.r), green: unit(c.g), blue: unit(c.b), alpha: unit(c.a))
    }
}
