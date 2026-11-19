// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
import AppSupport
import ProjectFormat
import SwiftUI

/// The camera's frame at the playhead in the Camera tab (`CameraStill`): its picture and its size in pixels, which the
/// framing's crop is worked out from.
struct CameraStillPicture: Equatable {
    var image: CGImage
    var frameSize: SIMD2<Int>
    /// Which instant of which track it is.
    var key: CameraStillKey

    static func == (a: Self, b: Self) -> Bool { a.key == b.key && a.frameSize == b.frameSize && a.image === b.image }
}

/// The camera's frame a still is asked for: track `track` at source instant `time`.
struct CameraStillKey: Hashable {
    var track: String
    var time: HostTime
}

/// The camera's shape where it is drawn: width over height of its rect, and its corner radius as a fraction of its shorter
/// side (0.5, a circle).
struct CameraShapeSeen: Equatable {
    var aspect: Double
    var cornerFraction: Double

    /// A circle, until a frame drawing the camera says otherwise.
    static let bubble = CameraShapeSeen(aspect: 1, cornerFraction: 0.5)
}

/// The small view of Manual framing (phase 2 design §6.2, plan 2b decision 19): the camera's whole frame at the playhead
/// as it is drawn (flipped with the mirror), dimmed outside the crop, which has the camera's shape. Dragging moves the crop
/// as it is seen; the scroll wheel or a pinch zooms; with the view focused, the arrow keys move it and + and − zoom.
/// VoiceOver reads the centre and the zoom, and can move and zoom it. While a drag, a scroll or a pinch lasts the model's
/// gesture shows it in the preview (`live`), and its end is one edit.
struct CameraFramingView: View {
    let model: EditorModel
    let still: CameraStillPicture?
    /// Whether a still was asked for and none could be made (no readable frame there).
    let stillMissing: Bool
    let shape: CameraShapeSeen
    let mirrored: Bool
    /// The document's framing.
    let framing: CameraFraming
    /// The framing a drag, a scroll or the zoom bar shows while it lasts.
    @Binding var live: CameraFraming?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    /// What the mouse or the trackpad is doing to the framing, one thing at a time.
    @State private var active: Active?

    private enum Active: Equatable {
        /// A drag from this centre, with the crop then.
        case drag(start: NormalizedPoint, crop: Rect)
        /// A scroll of the trackpad (a wheel's notches are steps of their own).
        case scroll
        /// A pinch from this zoom.
        case pinch(start: Double)
    }

    /// How far an arrow key moves the crop: 2 % of the frame.
    private static let keyStep = 0.02
    /// The tallest the view is, for a camera taller than wide.
    private static let maxHeight = 220.0

    private var shown: CameraFraming { live ?? framing }

    var body: some View {
        Group {
            if let still {
                picture(still)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - The picture

    private func picture(_ still: CameraStillPicture) -> some View {
        let frameSize = SIMD2(Double(still.frameSize.x), Double(still.frameSize.y))
        let crop = CameraFramingGeometry.crop(
            frameSize: frameSize, rectAspect: shape.aspect, center: SIMD2(shown.center.x, shown.center.y), zoom: shown.zoom)
        let seen = CameraFramingDrag.seenCrop(crop, mirrored: mirrored)
        return GeometryReader { proxy in
            let size: CGSize = proxy.size
            let rect: CGRect = Self.rect(of: seen, in: size)
            let radius: CGFloat = CGFloat(min(max(shape.cornerFraction, 0), 0.5)) * min(rect.width, rect.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: still.image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                    .frame(width: size.width, height: size.height)
                Self.dim(size: size, crop: rect, radius: radius)
                Self.outline(crop: rect, radius: radius)
                input(crop: crop, size: size)
            }
            .animation(active == nil && !reduceMotion ? Motion.selector.animation : nil, value: crop)
        }
        .aspectRatio(frameSize.x / frameSize.y, contentMode: .fit)
        .frame(maxHeight: Self.maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        .focusable(isEnabled)
        .onKeyPress(.leftArrow) { nudge(-1, 0, crop: crop) }
        .onKeyPress(.rightArrow) { nudge(1, 0, crop: crop) }
        .onKeyPress(.upArrow) { nudge(0, -1, crop: crop) }
        .onKeyPress(.downArrow) { nudge(0, 1, crop: crop) }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=-")) { press in
            zoomStep(press.characters == "-" ? -1 : 1)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Manual Framing"))
        .accessibilityValue(Text(verbatim: description))
        .accessibilityHint(Text("Drag to move the framing; scroll or pinch to zoom."))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: zoomStep(1)
            case .decrement: zoomStep(-1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Move Left")) { _ = nudge(-1, 0, crop: crop) }
        .accessibilityAction(named: Text("Move Right")) { _ = nudge(1, 0, crop: crop) }
        .accessibilityAction(named: Text("Move Up")) { _ = nudge(0, -1, crop: crop) }
        .accessibilityAction(named: Text("Move Down")) { _ = nudge(0, 1, crop: crop) }
    }

    /// `crop` (fractions of the frame, as seen) in a view of `size` points.
    private static func rect(of crop: Rect, in size: CGSize) -> CGRect {
        let width = Double(size.width), height = Double(size.height)
        return CGRect(x: crop.x * width, y: crop.y * height, width: crop.width * width, height: crop.height * height)
    }

    /// Everything but the crop, darker.
    private static func dim(size: CGSize, crop: CGRect, radius: CGFloat) -> some View {
        var path = Path()
        path.addRect(CGRect(origin: .zero, size: size))
        path.addRoundedRect(in: crop, cornerSize: CGSize(width: radius, height: radius))
        return path.fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
    }

    /// The crop's edge, in the camera's shape.
    private static func outline(crop: CGRect, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(Color.white, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.45), radius: 2)
            .frame(width: crop.width, height: crop.height)
            .offset(x: crop.minX, y: crop.minY)
    }

    /// What takes the mouse and the trackpad, over the whole picture of `size` points.
    private func input(crop: Rect, size: CGSize) -> some View {
        let viewSize = SIMD2(Double(size.width), Double(size.height))
        return FramingInput(
            enabled: isEnabled && model.canEdit,
            began: { kind in begin(kind, crop: crop) },
            dragged: { translation in drag(translation, viewSize: viewSize) },
            scrolled: { points, phased in scroll(points, phased: phased) },
            pinched: { scale in pinch(scale) },
            ended: end)
    }

    /// The centre as it is seen (flipped with the mirror) and the zoom: "Center: 52 % across, 40 % down; zoom 1.4×".
    private var description: String {
        let x = mirrored ? 1 - shown.center.x : shown.center.x
        return String(
            format: String(
                localized: "Center: %1$lld %% across, %2$lld %% down; zoom %3$@",
                comment: "VoiceOver: where the camera's manual framing is, as seen, and its zoom (“1.4×”)"),
            CameraPictureRules.percent(x), CameraPictureRules.percent(shown.center.y), CameraZoomText.text(shown.zoom))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.06))
            .overlay {
                VStack(spacing: 6) {
                    if stillMissing {
                        Image(systemName: "video.slash")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("The camera has no picture here.")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading the camera's picture…")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(8)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .aspectRatio(16.0 / 9, contentMode: .fit)
            .accessibilityElement(children: .combine)
    }

    // MARK: - What the mouse and the keys do

    private func begin(_ kind: FramingInput.Kind, crop: Rect) {
        guard active == nil, isEnabled, model.canEdit, !model.isGesturing else { return }
        switch kind {
        case .drag: active = .drag(start: shown.center, crop: crop)
        case .scroll: active = .scroll
        case .pinch: active = .pinch(start: shown.zoom)
        }
        live = shown
        model.beginGesture()
    }

    private func drag(_ translation: SIMD2<Double>, viewSize: SIMD2<Double>) {
        guard case let .drag(start, crop)? = active else { return }
        let center = CameraFramingDrag.center(from: start, drag: translation, viewSize: viewSize, crop: crop, mirrored: mirrored)
        live = CameraFraming(mode: shown.mode, center: center, zoom: shown.zoom)
        model.setFramingCenter(center)
    }

    /// A scroll of `points` up: inside a trackpad's scroll (`phased`) the gesture's; a wheel's notch, a step.
    private func scroll(_ points: Double, phased: Bool) {
        if phased {
            guard active == .scroll else { return }
            let zoom = CameraFramingDrag.zoom(shown.zoom, scroll: points)
            live = CameraFraming(mode: shown.mode, center: shown.center, zoom: zoom)
            model.setFramingZoom(zoom)
        } else {
            guard active == nil, isEnabled, !model.isGesturing else { return }
            let zoom = CameraFramingDrag.zoom(shown.zoom, scroll: points)
            if zoom != shown.zoom { model.setFramingZoom(zoom) }
        }
    }

    private func pinch(_ scale: Double) {
        guard case let .pinch(start)? = active else { return }
        let zoom = CameraFramingDrag.zoom(start, magnifiedBy: scale)
        live = CameraFraming(mode: shown.mode, center: shown.center, zoom: zoom)
        model.setFramingZoom(zoom)
    }

    private func end() {
        guard active != nil else { return }
        active = nil
        let changed = model.endGesture()
        // The document has the gesture's framing now (or never will: nothing changed): the view shows the document's.
        if !changed || model.document?.camera.framing == live { live = nil }
    }

    /// An arrow key (or VoiceOver's action): the crop moves 2 % of the frame the way it is seen.
    private func nudge(_ dx: Double, _ dy: Double, crop: Rect) -> KeyPress.Result {
        guard active == nil, isEnabled, !model.isGesturing else { return .ignored }
        let center = CameraFramingDrag.center(
            from: shown.center, drag: SIMD2(dx * Self.keyStep, dy * Self.keyStep), viewSize: SIMD2(1, 1), crop: crop, mirrored: mirrored)
        model.setFramingCenter(center)
        return .handled
    }

    /// + or − (or VoiceOver's adjustment): a step of the zoom bar.
    private func zoomStep(_ direction: Double) {
        guard active == nil, isEnabled, !model.isGesturing else { return }
        model.setFramingZoom(CameraPictureRules.snappedZoom(shown.zoom + direction * CameraPictureRules.zoomStep))
    }
}

/// The zoom as the tab writes it: "1.4×", with the locale's decimal separator.
enum CameraZoomText {
    static func text(_ zoom: Double) -> String {
        "\(zoom.formatted(.number.precision(.fractionLength(1))))×"
    }
}

// MARK: - The mouse and the trackpad

/// What the small view of the framing takes from the mouse and the trackpad, which SwiftUI does not give a view: the
/// drag, the scroll wheel (only a scroll that starts over it, so scrolling the panel past it never zooms) and the pinch.
/// It draws nothing and is not an element of its own for VoiceOver (the view around it is).
private struct FramingInput: NSViewRepresentable {
    enum Kind { case drag, scroll, pinch }

    let enabled: Bool
    let began: (Kind) -> Void
    /// The drag's translation from where it started, in points, x to the right and y down.
    let dragged: (SIMD2<Double>) -> Void
    /// Points scrolled up as the hand moves (whatever the direction of "natural" scrolling); whether it is inside a
    /// trackpad's scroll (`began` was called) or a wheel's notch.
    let scrolled: (Double, Bool) -> Void
    /// The pinch's magnification from where it started (1 is none).
    let pinched: (Double) -> Void
    let ended: () -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.input = self
        return view
    }

    func updateNSView(_ view: InputView, context: Context) {
        view.input = self
        view.window?.invalidateCursorRects(for: view)
    }

    final class InputView: NSView {
        var input: FramingInput?
        private var dragStart: NSPoint?
        /// A trackpad's scroll that started over the view, until it ends.
        private var scrolling = false
        private var magnification = 1.0

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func isAccessibilityElement() -> Bool { false }

        override func resetCursorRects() {
            guard input?.enabled == true else { return }
            addCursorRect(bounds, cursor: dragStart == nil ? .openHand : .closedHand)
        }

        override func mouseDown(with event: NSEvent) {
            guard let input, input.enabled else { return super.mouseDown(with: event) }
            dragStart = convert(event.locationInWindow, from: nil)
            window?.invalidateCursorRects(for: self)
            input.began(.drag)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            let point = convert(event.locationInWindow, from: nil)
            input?.dragged(SIMD2(Double(point.x - start.x), Double(point.y - start.y)))
        }

        override func mouseUp(with event: NSEvent) {
            guard dragStart != nil else { return }
            dragStart = nil
            window?.invalidateCursorRects(for: self)
            input?.ended()
        }

        override func scrollWheel(with event: NSEvent) {
            guard let input, input.enabled else { return super.scrollWheel(with: event) }
            // A momentum's tail: swallowed after the view's own scroll, the panel's otherwise.
            if !event.momentumPhase.isEmpty {
                if !scrolling { super.scrollWheel(with: event) }
                return
            }
            let delta = Double(event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY)
            let points = CameraFramingDrag.scrollPoints(delta: delta, precise: event.hasPreciseScrollingDeltas)
            if event.phase.isEmpty {
                // A wheel's notch.
                input.scrolled(points, false)
                return
            }
            if event.phase.contains(.began) {
                scrolling = true
                input.began(.scroll)
            } else if !scrolling {
                // A scroll that began elsewhere (the panel being scrolled) and passes over the view.
                return super.scrollWheel(with: event)
            }
            if event.phase.contains(.changed) { input.scrolled(points, true) }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                scrolling = false
                input.ended()
            }
        }

        override func magnify(with event: NSEvent) {
            guard let input, input.enabled else { return super.magnify(with: event) }
            if event.phase.contains(.began) {
                magnification = 1
                input.began(.pinch)
            }
            magnification *= 1 + Double(event.magnification)
            if event.phase.contains(.changed) { input.pinched(magnification) }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { input.ended() }
        }
    }
}
