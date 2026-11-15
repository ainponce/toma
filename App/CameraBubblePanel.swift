// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import AppSupport
import Observation
import ProjectFormat
import QuartzCore
import os

/// The camera's look (`RecorderSettings.cameraStyle`) and its permission: the one place they are read and
/// saved, for the bubble and the open island's camera column. Every change of style is saved at once, so the
/// next take starts with it (notch design §5.6).
@MainActor @Observable
final class CameraSetting {
    private(set) var style: CameraStyle
    /// The camera permission, as it was last read.
    private(set) var permission: PermissionState
    /// The system's camera prompt is up.
    private(set) var isAsking = false

    /// The system's prompt is about to show (`true`) or was answered (`false`): the island makes room for it.
    @ObservationIgnored var askingChanged: (Bool) -> Void = { _ in }
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let probe: any PermissionProbe

    init(store: SettingsStore, probe: any PermissionProbe) {
        self.store = store
        self.probe = probe
        style = store.settings.cameraStyle
        permission = probe.state(of: .camera)
    }

    func update(_ change: (inout CameraStyle) -> Void) {
        var changed = style
        change(&changed)
        guard changed != style else { return }
        style = changed
        var settings = store.settings
        settings.cameraStyle = changed
        store.settings = settings
    }

    /// Reads the permission again: it can change in System Settings.
    func refreshPermission() {
        let state = probe.state(of: .camera)
        if state != permission { permission = state }
    }

    /// Shows the system's prompt (`PermissionAction.prompt`); whether the camera is allowed once it is answered.
    func requestAccess() async -> Bool {
        guard !isAsking else { return false }
        isAsking = true
        askingChanged(true)
        let state = await probe.request(.camera)
        isAsking = false
        if state != permission { permission = state }
        askingChanged(false)
        return state == .granted
    }

    /// Once the prompt was answered no, only System Settings can allow the camera (`PermissionAction.openSettings`).
    func openSettings() {
        NSWorkspace.shared.open(PermissionSettings.url(for: .camera))
    }
}

/// The live camera bubble (notch design §5.3 and §5.6), seen while the camera is on and the island is in use
/// (`CameraBubbleLayout.isVisible`): a floating panel at `style.frame(in: region)`, the region being what is
/// recorded (`CameraBubbleLayout.region`, with the pointer's display among the chosen ones). It follows the
/// pointer 1:1 from where it was grabbed; let go, it goes to the place nearest to where its momentum takes it,
/// with a spring (`Motion.bubbleRelease`) that starts at the gesture's velocity, and a haptic tap as the place
/// is chosen. Shape and size changes are a spring too (`Motion.bubbleShape`); with "Reduce motion" every
/// change is immediate and appearing is a fade. While it is dragged the 8 places show. Its shadow is a panel
/// of its own under it, which lets the mouse through. It is never key. In the app its camera is
/// `SharedCameraPreview`: the session the take records, so the bubble and the camera track show the same camera,
/// and a change of camera takes both along.
@MainActor
final class CameraBubblePanel: NSObject {
    var reduceMotion = false

    private let setting: CameraSetting
    private let preview: any CameraPreviewProviding
    private let panel: FloatingPanel
    private let bubble: BubbleView
    private let shadow: FloatingPanel
    private let shadowView: BubbleShadowView
    private let places: FloatingPanel
    private let placesView: AnchorPlacesView
    /// What is recorded: the take's selection while there is one, otherwise the open island's.
    private var selection: @MainActor () -> CaptureSelection? = { nil }
    private var island = IslandState.rest
    /// The region the bubble is in, and what it was worked out from: it is worked out again only when that
    /// changes or the bubble appears, so it never jumps to another display under a pointer that moves.
    private var region: Rect?
    private var regionSource: RegionSource?
    /// The region the frame was last placed in.
    private var placedRegion: Rect?
    /// The camera the preview was last started with; `nil` while it is off.
    private var shownCamera: DeviceChoice?
    /// Only the newest start says whether the camera can be seen.
    private var previewGeneration = 0
    /// The bubble's frame in global coordinates (y down), and its corner radius.
    private var x: SpringValue
    private var y: SpringValue
    private var width: SpringValue
    private var height: SpringValue
    private var radius: SpringValue
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    private var drag: Drag?
    /// The panel is fading out, to leave the screen.
    private var isHiding = false
    /// For the life of the app.
    private var observers: [any NSObjectProtocol] = []

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Camera")

    private struct RegionSource: Equatable {
        let mode: CaptureMode
        let displayIDs: [UInt32]
        let windowID: UInt32?
        let area: AreaChoice?

        init(_ selection: CaptureSelection) {
            mode = selection.mode
            displayIDs = selection.displayIDs
            windowID = selection.windowID
            area = selection.area
        }
    }

    private struct Drag {
        /// From the bubble's top left to the pointer, where it was grabbed.
        let grab: CGVector
        var samples: [CameraBubbleLayout.DragSample]
        /// It moved since it was grabbed, or was still moving when it was.
        var moved: Bool
    }

    init(setting: CameraSetting, preview: any CameraPreviewProviding) {
        self.setting = setting
        self.preview = preview
        let frame = NSRect(x: 0, y: 0, width: 180, height: 180)
        panel = FloatingPanel(contentRect: frame, level: FloatingPanel.floatingLevel, ignoresMouseEvents: false)
        bubble = BubbleView(frame: frame, preview: preview.previewLayer)
        let around = frame.insetBy(dx: -BubbleShadowView.margin, dy: -BubbleShadowView.margin)
        shadow = FloatingPanel(contentRect: around, level: FloatingPanel.floatingLevel, ignoresMouseEvents: true)
        shadowView = BubbleShadowView(frame: NSRect(origin: .zero, size: around.size))
        places = FloatingPanel(contentRect: frame, level: FloatingPanel.floatingLevel, ignoresMouseEvents: true)
        placesView = AnchorPlacesView(frame: frame)
        x = SpringValue(value: 0, spring: Motion.bubbleShape)
        y = SpringValue(value: 0, spring: Motion.bubbleShape)
        width = SpringValue(value: 180, spring: Motion.bubbleShape)
        height = SpringValue(value: 180, spring: Motion.bubbleShape)
        radius = SpringValue(value: 90, spring: Motion.bubbleShape)
        super.init()

        panel.contentView = bubble
        shadowView.autoresizingMask = [.width, .height]
        shadow.contentView = shadowView
        placesView.autoresizingMask = [.width, .height]
        places.contentView = placesView
        bubble.pressed = { [weak self] event in self?.dragBegan(event) }
        bubble.dragged = { [weak self] event in self?.dragMoved(event) }
        bubble.released = { [weak self] event in self?.dragEnded(event) }
        let link = bubble.displayLink(target: self, selector: #selector(frameTick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        // A camera connected or disconnected: the preview goes to the camera the choice resolves to now.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.camerasChanged() }
            }
            observers.append(token)
        }
    }

    /// From now on the bubble shows what `selection` says is recorded, and follows its changes and the style's.
    func follow(_ selection: @escaping @MainActor () -> CaptureSelection?) {
        self.selection = selection
        observe()
        refresh()
    }

    /// The island is now in `state`.
    func update(island state: IslandState) {
        island = state
        refresh()
    }

    /// Displays were connected or disconnected, or changed: the region is worked out again.
    func screensChanged() {
        regionSource = nil
        refresh()
    }

    // MARK: - What it shows

    private func observe() {
        withObservationTracking {
            _ = selection()
            _ = setting.style
            _ = setting.permission
        } onChange: { [weak self] in
            // Called before the change: read it once it is made.
            Task { @MainActor in
                self?.observe()
                self?.refresh()
            }
        }
    }

    private var isShown: Bool { panel.isVisible && !isHiding }

    private func refresh() {
        let selection = selection()
        let cameraOn = selection.map { $0.camera != .off } == true && setting.permission == .granted
        guard let selection, CameraBubbleLayout.isVisible(cameraOn: cameraOn, island: island),
            let region = region(for: selection)
        else {
            hide()
            return
        }
        show(selection.camera, in: region)
    }

    private func region(for selection: CaptureSelection) -> Rect? {
        let source = RegionSource(selection)
        if !isShown || source != regionSource {
            regionSource = source
            region = CameraBubbleLayout.region(
                for: selection, displays: LiveTakeEnvironment.displays(), pointer: Self.pointer(), windowFrame: nil)
        }
        return region
    }

    /// On the screen at the style's frame in `region`: there at once if it is appearing or the region changed,
    /// otherwise with the shape spring (never under the pointer that drags it).
    private func show(_ camera: DeviceChoice, in region: Rect) {
        let appearing = !panel.isVisible
        let target = setting.style.frame(in: region)
        if appearing || region != placedRegion {
            placedRegion = region
            land(on: target)
        } else if drag == nil {
            head(to: target)
        }
        if appearing {
            panel.alphaValue = 0
            shadow.alphaValue = 0
            panel.orderFrontRegardless()
            shadow.orderFrontRegardless()
            panel.addChildWindow(shadow, ordered: .below)
        }
        if appearing || isHiding {
            isHiding = false
            fade(to: 1)
        }
        if camera != shownCamera { startPreview(camera) }
    }

    private func hide() {
        endDrag()
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        fade(to: 0) { [weak self] in
            guard let self, isHiding else { return }
            isHiding = false
            panel.removeChildWindow(shadow)
            shadow.orderOut(nil)
            panel.orderOut(nil)
            displayLink?.isPaused = true
            lastFrameTime = nil
            previewGeneration += 1
            preview.stop()
            shownCamera = nil
            // Next time it shows what that start says, not what the last one said.
            bubble.isUnavailable = false
        }
    }

    private func fade(to alpha: CGFloat, then completion: (@MainActor () -> Void)? = nil) {
        let duration = (reduceMotion ? Motion.reducedMotionFade : Motion.contentExit).timeInterval
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
            shadow.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    // MARK: - The camera

    private func startPreview(_ camera: DeviceChoice) {
        shownCamera = camera
        previewGeneration += 1
        let generation = previewGeneration
        let uniqueID: String? = if case .device(let id) = camera { id } else { nil }
        Task { [weak self, preview] in
            do {
                try await preview.start(deviceUniqueID: uniqueID)
                guard let self, generation == previewGeneration else { return }
                bubble.isUnavailable = false
            } catch {
                // It shows no camera at all (`CameraPreviewProviding.start`).
                Self.logger.error("Cannot show the camera: \(String(describing: error), privacy: .public)")
                guard let self, generation == previewGeneration else { return }
                bubble.isUnavailable = true
            }
        }
    }

    private func camerasChanged() {
        guard let shownCamera, isShown else { return }
        startPreview(shownCamera)
    }

    // MARK: - Dragging

    /// Caught where it is: it stops there. Caught in flight it is lifted at once (the places show and the shadow
    /// deepens); at rest, once it moves, so a click that does not move it shows nothing.
    private func dragBegan(_ event: NSEvent) {
        guard isShown, placedRegion != nil else { return }
        let wasMoving = !(x.isSettled && y.isSettled)
        hold(at: CGPoint(x: x.value, y: y.value))
        let pointer = Self.pointer()
        drag = Drag(
            grab: CGVector(dx: pointer.x - x.value, dy: pointer.y - y.value),
            samples: [.init(time: event.timestamp, point: CGPoint(x: x.value, y: y.value))], moved: wasMoving)
        if wasMoving { lift() }
    }

    /// 1:1 with the pointer.
    private func dragMoved(_ event: NSEvent) {
        guard var drag else { return }
        let pointer = Self.pointer()
        let origin = CGPoint(x: pointer.x - drag.grab.dx, y: pointer.y - drag.grab.dy)
        if !drag.moved, origin.x != x.value || origin.y != y.value {
            drag.moved = true
            lift()
        }
        hold(at: origin)
        drag.samples.append(.init(time: event.timestamp, point: origin))
        drag.samples.removeAll { $0.time < event.timestamp - 2 * CameraBubbleLayout.releaseVelocitySpan }
        self.drag = drag
        applyFrame()
    }

    /// Let go: the place is chosen now, with the haptic tap (the trackpad cannot tap a finger that has left it),
    /// and the bubble springs there from the gesture's velocity. A click that did not move it changes nothing.
    private func dragEnded(_ event: NSEvent) {
        guard var drag, let region = placedRegion else { return }
        endDrag()
        guard drag.moved else { return }
        let origin = CGPoint(x: x.value, y: y.value)
        drag.samples.append(.init(time: event.timestamp, point: origin))
        let velocity = CameraBubbleLayout.releaseVelocity(samples: drag.samples, at: event.timestamp)
        var style = setting.style
        style.anchor = CameraBubbleLayout.releaseAnchor(origin: origin, velocity: velocity, style: style, region: region)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        let target = style.frame(in: region).rect
        if reduceMotion {
            hold(at: CGPoint(x: target.x, y: target.y))
            applyFrame()
        } else {
            x.velocity = Double(velocity.dx)
            y.velocity = Double(velocity.dy)
            x.retarget(target.x, spring: Motion.bubbleRelease)
            y.retarget(target.y, spring: Motion.bubbleRelease)
            run()
        }
        // The style's frame is where the springs are going now: saving it moves nothing.
        setting.update { $0.anchor = style.anchor }
    }

    /// Put down: the places go and the shadow is back, if it was lifted.
    private func endDrag() {
        guard let drag else { return }
        self.drag = nil
        guard drag.moved else { return }
        places.orderOut(nil)
        shadowView.setLifted(false, animated: !reduceMotion)
    }

    /// The bubble is being dragged: the 8 places of its region show, under it and its shadow, and the shadow deepens.
    private func lift() {
        guard let region = placedRegion else { return }
        shadowView.setLifted(true, animated: !reduceMotion)
        places.setFrame(ScreenCoordinates.appKit(fromGlobal: region, primaryScreenHeight: Self.primaryScreenHeight), display: false)
        let centers = CameraBubbleLayout.anchorFrames(style: setting.style, region: region).map { place in
            CGPoint(x: place.rect.x + place.rect.width / 2 - region.x, y: place.rect.y + place.rect.height / 2 - region.y)
        }
        placesView.show(at: centers, reduceMotion: reduceMotion)
        places.orderFrontRegardless()
        // Its shadow, a child window, comes along under it.
        panel.orderFrontRegardless()
    }

    // MARK: - Frame

    /// Still at `origin`, keeping its size and its corners (which may still be on their way).
    private func hold(at origin: CGPoint) {
        x = SpringValue(value: Double(origin.x), spring: x.spring)
        y = SpringValue(value: Double(origin.y), spring: y.spring)
    }

    /// Everything on `frame` at once.
    private func land(on frame: CameraFrame) {
        x = SpringValue(value: frame.rect.x, spring: Motion.bubbleShape)
        y = SpringValue(value: frame.rect.y, spring: Motion.bubbleShape)
        width = SpringValue(value: frame.rect.width, spring: Motion.bubbleShape)
        height = SpringValue(value: frame.rect.height, spring: Motion.bubbleShape)
        radius = SpringValue(value: frame.cornerRadius, spring: Motion.bubbleShape)
        displayLink?.isPaused = true
        lastFrameTime = nil
        applyFrame()
    }

    /// Heads for `frame` with the shape spring from where it is, at the speed it has (what is already headed
    /// there keeps its spring); with "Reduce motion" it is there at once.
    private func head(to frame: CameraFrame) {
        let targets = [frame.rect.x, frame.rect.y, frame.rect.width, frame.rect.height, frame.cornerRadius]
        guard targets != [x.target, y.target, width.target, height.target, radius.target] else { return }
        if reduceMotion {
            land(on: frame)
            return
        }
        func retarget(_ spring: inout SpringValue, _ target: Double) {
            if spring.target != target { spring.retarget(target, spring: Motion.bubbleShape) }
        }
        retarget(&x, frame.rect.x)
        retarget(&y, frame.rect.y)
        retarget(&width, frame.rect.width)
        retarget(&height, frame.rect.height)
        retarget(&radius, frame.cornerRadius)
        run()
    }

    private func run() {
        guard let displayLink, displayLink.isPaused else { return }
        lastFrameTime = nil
        displayLink.isPaused = false
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        let time = link.timestamp
        // At most one 30th of a second per frame: after a hitch the motion slows down instead of jumping.
        let seconds = lastFrameTime.map { min(max(time - $0, 0), 1.0 / 30) } ?? max(link.targetTimestamp - link.timestamp, 0)
        lastFrameTime = time
        x.step(by: seconds)
        y.step(by: seconds)
        width.step(by: seconds)
        height.step(by: seconds)
        radius.step(by: seconds)
        applyFrame()
        if x.isSettled, y.isSettled, width.isSettled, height.isSettled, radius.isSettled {
            link.isPaused = true
            lastFrameTime = nil
        }
    }

    /// The window's frame is the bubble as it is now; its corners are never rounder than its shorter side.
    private func applyFrame() {
        let size = (width: max(1, width.value), height: max(1, height.value))
        let rect = Rect(x: x.value, y: y.value, width: size.width, height: size.height)
        let frame = ScreenCoordinates.appKit(fromGlobal: rect, primaryScreenHeight: Self.primaryScreenHeight)
        let corner = min(max(0, radius.value), min(size.width, size.height) / 2)
        panel.setFrame(frame, display: true)
        bubble.cornerRadius = corner
        shadow.setFrame(frame.insetBy(dx: -BubbleShadowView.margin, dy: -BubbleShadowView.margin), display: false)
        shadowView.shape(size: frame.size, cornerRadius: corner)
    }

    private static var primaryScreenHeight: Double {
        Double(NSScreen.screens.first?.frame.height ?? 0)
    }

    /// Where the pointer is, in global coordinates.
    private static func pointer() -> CGPoint {
        let pointer = ScreenCoordinates.global(
            fromAppKit: CGRect(origin: NSEvent.mouseLocation, size: .zero), primaryScreenHeight: primaryScreenHeight)
        return CGPoint(x: pointer.x, y: pointer.y)
    }
}

/// The bubble: the camera filling it (aspect fill), its corners cut, a light border, and a slashed camera
/// when the camera cannot be shown. It passes the mouse to the panel.
private final class BubbleView: NSView {
    var pressed: (NSEvent) -> Void = { _ in }
    var dragged: (NSEvent) -> Void = { _ in }
    var released: (NSEvent) -> Void = { _ in }

    var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            layer?.cornerRadius = cornerRadius
        }
    }

    var isUnavailable = false {
        didSet { symbol.isHidden = !isUnavailable }
    }

    private let preview: CALayer
    private let symbol = NSImageView()

    init(frame: NSRect, preview: CALayer) {
        self.preview = preview
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        autoresizingMask = [.width, .height]
        guard let layer else { return }
        layer.masksToBounds = true
        layer.cornerCurve = .circular
        layer.backgroundColor = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.102, alpha: 1).cgColor
        // Drawn over the camera.
        layer.borderWidth = 3
        layer.borderColor = NSColor(white: 1, alpha: 0.92).cgColor
        layer.addSublayer(preview)
        symbol.image = NSImage(systemSymbolName: "video.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular).applying(.init(hierarchicalColor: .white)))
        symbol.alphaValue = 0.6
        symbol.isHidden = true
        addSubview(symbol)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // By bounds and position: the layer may be mirrored by a transform.
        preview.bounds = bounds
        preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        let side = 30.0
        symbol.frame = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed(event) }
    override func mouseDragged(with event: NSEvent) { dragged(event) }
    override func mouseUp(with event: NSEvent) { released(event) }
}

/// The bubble's shadow (the prototype's): a close one and a soft one, deeper while the bubble is dragged.
private final class BubbleShadowView: NSView {
    /// Room around the bubble for the soft shadow, lifted (24 pt down, 25 pt of radius) included.
    static let margin = 80.0

    private let close = CALayer()
    private let soft = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for layer in [close, soft] {
            layer.shadowColor = NSColor.black.cgColor
            self.layer?.addSublayer(layer)
        }
        close.shadowOpacity = 0.2
        close.shadowRadius = 3
        close.shadowOffset = CGSize(width: 0, height: -2)
        setLifted(false, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The bubble is `size` with `cornerRadius`, in the middle of the view.
    func shape(size: CGSize, cornerRadius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGPath(
            roundedRect: CGRect(origin: .zero, size: size), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        for layer in [close, soft] {
            layer.frame = CGRect(x: Self.margin, y: Self.margin, width: size.width, height: size.height)
            layer.shadowPath = path
        }
        CATransaction.commit()
    }

    /// Deeper while dragged: 24 pt down and 50 pt of blur instead of 14 and 30.
    func setLifted(_ lifted: Bool, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Motion.contentExit.timeInterval)
        soft.shadowOpacity = lifted ? 0.5 : 0.42
        soft.shadowRadius = lifted ? 25 : 15
        soft.shadowOffset = CGSize(width: 0, height: lifted ? -24 : -14)
        CATransaction.commit()
    }
}

/// The 8 places while the bubble is dragged: a small light dot at the center of each, which grows in (with
/// "Reduce motion", fades in).
private final class AnchorPlacesView: NSView {
    private let dots: [CALayer]

    override init(frame: NSRect) {
        dots = CameraAnchor.allCases.map { _ in
            let ring = CALayer()
            ring.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
            ring.cornerRadius = 8
            ring.backgroundColor = NSColor(white: 1, alpha: 0.15).cgColor
            let dot = CALayer()
            dot.frame = CGRect(x: 4, y: 4, width: 8, height: 8)
            dot.cornerRadius = 4
            dot.backgroundColor = NSColor(white: 1, alpha: 0.7).cgColor
            ring.addSublayer(dot)
            return ring
        }
        super.init(frame: frame)
        wantsLayer = true
        for dot in dots { layer?.addSublayer(dot) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Top-left origin, like the region the centers are in.
    override var isFlipped: Bool { true }

    func show(at centers: [CGPoint], reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (dot, center) in zip(dots, centers) {
            dot.position = center
            dot.removeAllAnimations()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            if reduceMotion {
                fade.duration = Motion.reducedMotionFade.timeInterval
                dot.add(fade, forKey: "appear")
            } else {
                let grow = CASpringAnimation(keyPath: "transform.scale", spring: Motion.selector)
                grow.fromValue = 0.3
                grow.toValue = 1
                fade.duration = grow.duration
                let group = CAAnimationGroup()
                group.animations = [grow, fade]
                group.duration = grow.duration
                dot.add(group, forKey: "appear")
            }
        }
        CATransaction.commit()
    }
}

extension CASpringAnimation {
    /// A spring of the design (damping ratio and response) as Core Animation's mass, stiffness and damping.
    convenience init(keyPath: String, spring: AppSupport.Spring) {
        self.init(keyPath: keyPath)
        let omega = 2 * Double.pi / spring.response
        mass = 1
        stiffness = omega * omega
        damping = 2 * spring.damping * omega
        duration = settlingDuration
    }
}
