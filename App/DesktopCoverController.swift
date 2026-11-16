// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import QuartzCore
import os

/// Hides the desktop's icons while recording ("Hide Desktop Icons"): a cover over the desktop of each screen, just
/// above its icons and widgets and under every window, that shows the screen's wallpaper as it is seen
/// (`WallpaperSnapshot.capture`; if that fails, the wallpaper's image where macOS draws it, `WallpaperLayout`, over the
/// fill color). The covers ignore the mouse (a click goes to the desktop below), are on every desktop, never take the
/// keyboard and never activate the app. Each desktop can have its own wallpaper, so a change of desktop captures it
/// again; a change of the screens' arrangement or resolution fits the covers to their screens again, takes the cover of
/// a screen that is gone off the screen (kept, with its window ID, until `hide()`) and puts it back when that screen
/// returns. The screens are captured at the same time, each with `WallpaperSnapshot.captureTimeLimit`: a
/// ScreenCaptureKit that does not answer holds the countdown back that long at most, and the cover draws the
/// wallpaper's image instead. The take records them on purpose (`TakePreparation.includedWindowIDs`): the video shows
/// the wallpaper where the icons are. Finder's settings are never touched.
@MainActor
final class DesktopCoverController {
    /// Just above the desktop's icons, far under the windows of every app.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    private struct Cover {
        let displayID: UInt32
        let panel: FloatingPanel
        let view: WallpaperView
    }

    private var covers: [Cover] = []
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var redrawing: Task<Void, Never>?
    /// Changed by every `hide()`: a `show()` that was still capturing then puts nothing up.
    private var generation = 0

    nonisolated private static let logger = Logger(subsystem: "dev.toma.Toma", category: "DesktopCover")

    /// Puts a cover over the desktop of every screen, each with its wallpaper, and returns their window IDs once
    /// they are on the screen. Covers already up stay as they are.
    func show() async -> [UInt32] {
        guard covers.isEmpty else { return windowIDs }
        let started = generation
        let screens = NSScreen.screens.compactMap { screen in screen.displayID.map { (screen: screen, displayID: $0) } }
        let wallpapers = await Self.wallpapers(of: screens)
        guard generation == started else { return [] }
        for ((screen, displayID), wallpaper) in zip(screens, wallpapers) {
            let view = WallpaperView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.show(wallpaper)
            let panel = FloatingPanel(contentRect: screen.frame, level: Self.level, ignoresMouseEvents: true)
            panel.contentView = view
            panel.orderFrontRegardless()
            covers.append(Cover(displayID: displayID, panel: panel, view: view))
        }
        observeChanges()
        Self.logger.notice("Covering the desktop icons of displays \(self.covers.map(\.displayID), privacy: .public)")
        return windowIDs
    }

    /// Takes the covers away; the desktop's icons show again.
    func hide() {
        generation += 1
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        redrawing?.cancel()
        redrawing = nil
        for cover in covers {
            cover.panel.orderOut(nil)
            cover.panel.close()
        }
        covers = []
    }

    private var windowIDs: [UInt32] {
        covers.compactMap { $0.panel.windowNumber > 0 ? UInt32($0.panel.windowNumber) : nil }
    }

    /// A change of desktop (posted to the workspace's notification center) and of the screens.
    private func observeChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        let spaces = workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        let app = NotificationCenter.default
        let screens = app.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refit() }
        }
        observers = [(workspace, spaces), (app, screens)]
    }

    /// Each cover over its screen's frame now, drawn again. The cover of a screen that is gone is taken off the screen
    /// but kept: macOS would move it to another screen, over that one's cover, and a new window would not be in the
    /// take's request (its displays' filter keeps the covers by window ID, also off the screen). When the screen
    /// returns, its cover goes back over it.
    private func refit() {
        for cover in covers {
            guard let screen = Self.screen(cover.displayID) else {
                if cover.panel.isVisible {
                    Self.logger.notice("Display \(cover.displayID, privacy: .public) is gone: its cover is put away")
                    cover.panel.orderOut(nil)
                }
                continue
            }
            cover.panel.setFrame(screen.frame, display: false)
            if !cover.panel.isVisible {
                Self.logger.notice("Display \(cover.displayID, privacy: .public) is back: its cover is up again")
                cover.panel.orderFrontRegardless()
            }
        }
        redraw()
    }

    /// Captures the wallpaper of each screen with a cover again, as the desktop now on it shows it, and draws it; a
    /// redraw still capturing is given up.
    private func redraw() {
        redrawing?.cancel()
        let shown = covers.compactMap { cover in Self.screen(cover.displayID).map { (cover: cover, screen: $0) } }
        redrawing = Task {
            let wallpapers = await Self.wallpapers(of: shown.map { (screen: $0.screen, displayID: $0.cover.displayID) })
            guard !Task.isCancelled else { return }
            for (item, wallpaper) in zip(shown, wallpapers) { item.cover.view.show(wallpaper) }
        }
    }

    private static func screen(_ displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    /// The wallpaper of each of `screens` as it is seen, in their order, all captured at the same time; one that cannot
    /// be captured within `captureTimeLimit` is its image as macOS draws it.
    private static func wallpapers(of screens: [(screen: NSScreen, displayID: UInt32)]) async -> [Wallpaper] {
        let displayIDs = screens.map(\.displayID)
        let captured = await withTaskGroup(of: (index: Int, image: CGImage?).self) { group in
            for (index, displayID) in displayIDs.enumerated() {
                group.addTask { (index, await capture(displayID)) }
            }
            var images = [CGImage?](repeating: nil, count: displayIDs.count)
            for await result in group { images[result.index] = result.image }
            return images
        }
        return zip(screens, captured).map { screen, image in image.map(Wallpaper.captured) ?? picture(on: screen.screen) }
    }

    /// The wallpaper of `displayID` as it is seen; `nil`, logged, if it cannot be captured within `captureTimeLimit`.
    nonisolated private static func capture(_ displayID: UInt32) async -> CGImage? {
        do {
            return try await withTimeLimit(WallpaperSnapshot.captureTimeLimit) {
                try await WallpaperSnapshot.capture(displayID: displayID)
            }
        } catch {
            logger.error(
                "Cannot capture the wallpaper of display \(displayID, privacy: .public), drawing its image: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// `desktopImageURL(for:)` with `desktopImageOptions(for:)` (macOS fills the screen by default), over the fill
    /// color; the fill color alone if the image cannot be read.
    private static func picture(on screen: NSScreen) -> Wallpaper {
        let workspace = NSWorkspace.shared
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let fill = (options[.fillColor] as? NSColor)?.cgColor ?? NSColor.black.cgColor
        guard let url = workspace.desktopImageURL(for: screen), let image = NSImage(contentsOf: url),
            let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            logger.error("Cannot read the wallpaper's image: the cover shows its fill color")
            return .fill(fill)
        }
        let scaling =
            (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        let rect = WallpaperLayout.imageRect(
            imageSize: image.size, screenSize: screen.frame.size, scaling: scaling, allowsClipping: clipping)
        return .picture(picture, in: rect, fill: fill)
    }
}

/// What a cover shows.
private enum Wallpaper {
    /// The screen's wallpaper as it is seen, the size of the screen.
    case captured(CGImage)
    /// The wallpaper's image at `rect` (the screen's points), over `fill`.
    case picture(CGImage, in: CGRect, fill: CGColor)
    /// Only the fill color.
    case fill(CGColor)
}

/// A cover's content: a layer of its own (the view hosts it, so AppKit never draws into it) and, for a picture, the
/// image where macOS draws it.
private final class WallpaperView: NSView {
    private let root = CALayer()
    private let image = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.frame = bounds
        root.contentsGravity = .resize
        image.contentsGravity = .resize
        root.addSublayer(image)
        // Set before `wantsLayer`: the view hosts the layer.
        layer = root
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The layer follows the view: the cover is fitted to its screen again when the screen changes.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        CATransaction.commit()
    }

    func show(_ wallpaper: Wallpaper) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch wallpaper {
        case .captured(let captured):
            root.backgroundColor = NSColor.black.cgColor
            root.contents = captured
            image.contents = nil
        case let .picture(picture, rect, fill):
            root.backgroundColor = fill
            root.contents = nil
            image.contents = picture
            image.frame = rect
        case .fill(let fill):
            root.backgroundColor = fill
            root.contents = nil
            image.contents = nil
        }
        CATransaction.commit()
    }
}
