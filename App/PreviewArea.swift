// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Library
import ProjectFormat
import QuartzCore
import SwiftUI

/// The preview's part of the window (design §5.3): the banner on top, then, on a fixed dark gray in light and dark mode
/// alike (#161618: colors are judged against a dark neutral), the video with 16 pt around it in the format's proportion
/// and the transport under it: `0:42,18  ⏮ ▶/⏸ ⏭  2:14,00`. Before it can show the video, what stands in its place:
/// "Opening…", a take that didn't finish saving, a project that couldn't be opened, or one of a newer version.
struct PreviewArea: View {
    let model: EditorModel

    /// The gray around the video.
    static let background = Color(red: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x18 / 255.0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            EditorBanners(model: model)
            ZStack {
                Self.background
                content
                    .environment(\.colorScheme, .dark)
            }
        }
        .navigationTitle(Text(verbatim: model.name))
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .opening:
            ProgressView("Opening…")
        case .unfinished where model.isInTrash:
            // In the trash it is restored first, never recovered there (Task 39, ruling 2).
            ContentUnavailableView {
                Label("This recording hasn't finished saving", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: EditorBanners.text(ReadOnlyReason.inTrash))
            } actions: {
                if let actions = model.projectActions {
                    Button(LibraryActions.title(.restore, items: [])) { actions.restore() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!actions.canRestore)
                }
            }
        case .unfinished:
            ContentUnavailableView {
                Label("This recording hasn't finished saving", systemImage: "exclamationmark.triangle")
            } description: {
                Text("If it isn't being recorded now, click Recover. Nothing recorded is deleted.")
            } actions: {
                Button("Recover") { model.recover() }
                    .keyboardShortcut(.defaultAction)
            }
        case .recovering:
            ProgressView("Recovering…")
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't open the project", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            }
        case .newerDocument:
            ContentUnavailableView {
                Label {
                    Text(verbatim: EditorBanners.text(.newerDocument(0)))
                } icon: {
                    Image(systemName: "arrow.down.app")
                }
            }
        case .ready:
            VStack(spacing: 12) {
                PreviewSurface(model: model)
                    .overlay { PreviewOverlay(model: model) }
                    .overlay {
                        // Over the preview only, never in the render (`safeZones-1`).
                        if model.showsSafeZones, SafeZones.applies(ratio: model.previewRatio) {
                            SafeZonesOverlay().transition(.opacity)
                        }
                    }
                    .animation(.panel(Motion.hover, reduceMotion: reduceMotion), value: model.showsSafeZones)
                    .aspectRatio(CGFloat(model.previewRatio), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Transport(model: model)
                    .typingSpeedPopover(model)
            }
            .padding(16)
        }
    }
}

/// ⏮ (to the start), ▶/⏸ and ⏭ (to the end), centered under the video, between the time of the playhead (on their left)
/// and what the output lasts (on their right, secondary).
private struct Transport: View {
    let model: EditorModel

    var body: some View {
        let total = model.durationSeconds
        HStack(spacing: 0) {
            let current = Timecode.precise(model.currentSeconds, total: total, locale: .current)
            let length = Timecode.precise(total, total: total, locale: .current)
            Text(verbatim: current)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(Text("Playhead", comment: "VoiceOver: the time of the playhead under the preview"))
                .accessibilityValue(Text(verbatim: current))
            HStack(spacing: 6) {
                Button {
                    model.seekToStart()
                } label: {
                    Label("Go to the Beginning", systemImage: "backward.end.fill")
                }
                .help(Text("Go to the Beginning"))
                Button {
                    model.togglePlay()
                } label: {
                    if model.isPlaying {
                        Label("Pause", systemImage: "pause.fill")
                    } else {
                        Label("Play", systemImage: "play.fill")
                    }
                }
                .buttonStyle(TransportButtonStyle(prominent: true))
                .keyboardShortcut(.space, modifiers: [])
                .help(model.isPlaying ? Text("Pause") : Text("Play"))
                Button {
                    model.seekToEnd()
                } label: {
                    Label("Go to the End", systemImage: "forward.end.fill")
                }
                .help(Text("Go to the End"))
            }
            .padding(.horizontal, 18)
            Text(verbatim: length)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Duration"))
                .accessibilityValue(Text(verbatim: length))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(TransportButtonStyle())
        .monospacedDigit()
        .disabled(!model.canPlay)
        .overlay(alignment: .trailing) {
            // The safe-zone guide's switch, for the formats it applies to (4:5 and narrower).
            if SafeZones.applies(ratio: model.previewRatio) {
                Toggle(isOn: Bindable(model).showsSafeZones) {
                    Label("Show Safe Zones", systemImage: "rectangle.dashed")
                }
                .toggleStyle(SafeZonesToggleStyle())
                .help(model.showsSafeZones ? Text("Hide Safe Zones") : Text("Show Safe Zones"))
            }
        }
    }
}

/// The safe-zone button of the transport: the symbol in the transport's circle, in the brand's violet while on.
private struct SafeZonesToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(TransportButtonStyle())
            .labelStyle(.iconOnly)
            .foregroundStyle(configuration.isOn ? Color.accentColor : Color.primary)
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// A button of the transport: its symbol in a circle that shows while the mouse is over it, darker and a little smaller
/// while pressed (not smaller with "Reduce motion"); the prominent one (▶/⏸) larger, its circle always there.
private struct TransportButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        TransportButton(configuration: configuration, prominent: prominent)
    }
}

private struct TransportButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let side: CGFloat = prominent ? 36 : 30
        let rest = prominent ? 0.10 : 0
        let fill = configuration.isPressed ? 0.20 : (hovering && isEnabled ? rest + 0.08 : rest)
        configuration.label
            .font(.system(size: prominent ? 16 : 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: side, height: side)
            .background(Circle().fill(Color.primary.opacity(fill)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { hovering = $0 }
            .animation(.panel(Motion.hover, reduceMotion: reduceMotion), value: hovering)
            .animation(.panel(Motion.selector, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// The view the preview engine draws into: it hosts the model's `CAMetalLayer`, keeps the layer's drawable at its size
/// in pixels, and, while playing, asks for a frame on each refresh of its display.
private struct PreviewSurface: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> PreviewSurfaceView {
        PreviewSurfaceView(model: model)
    }

    func updateNSView(_ view: PreviewSurfaceView, context: Context) {
        view.setPlaying(model.isPlaying)
        view.setAccessibilityValue(Timecode.precise(model.currentSeconds, total: model.durationSeconds, locale: .current))
    }

    static func dismantleNSView(_ view: PreviewSurfaceView, coordinator: ()) {
        view.stopDisplayLink()
    }
}

/// See `PreviewSurface`. A click plays or pauses, as in QuickTime (a double click does nothing more: only its first
/// click counts); a drag does not. It takes the keyboard's focus with a click, or Tab and ⇧Tab, and shows the system's
/// focus ring around the video: its keys are then the window's (`EditorKeyboard`). VoiceOver reads it as "Preview", its
/// value the playhead's time.
final class PreviewSurfaceView: NSView {
    private let model: EditorModel
    private var displayLink: CADisplayLink?
    private var isPlaying = false
    private var mouseDownPoint: NSPoint?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        // Layer-hosting: the layer first, then `wantsLayer`.
        layer = model.previewLayer
        wantsLayer = true
        model.previewLayer.contentsGravity = .resizeAspect
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Preview"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopDisplayLink()
        guard window != nil else { return }
        // In the common modes, so playback goes on while a menu, a slider or a scroll is tracking.
        let link = displayLink(target: self, selector: #selector(displayTick(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = !isPlaying
        displayLink = link
        updateDrawableSize()
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        displayLink?.isPaused = !playing
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        model.displayTick()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        noteFocusRingMaskChanged()
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        bounds.fill()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    /// The layer's drawable is the view's size in pixels; paused, the frame is drawn again at it.
    private func updateDrawableSize() {
        let pixels = convertToBacking(bounds).size
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let layer = model.previewLayer
        guard layer.drawableSize != pixels || layer.contentsScale != scale else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        layer.drawableSize = pixels
        CATransaction.commit()
        model.redrawPaused()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownPoint = event.clickCount == 1 ? convert(event.locationInWindow, from: nil) : nil
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard let start = mouseDownPoint else { return }
        let end = convert(event.locationInWindow, from: nil)
        guard hypot(end.x - start.x, end.y - start.y) < 4 else { return }
        model.togglePlay()
    }
}
