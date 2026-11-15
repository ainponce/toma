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
/// again; a change of the screens' arrangement or resolution fits the covers to their screens again. The take records
/// them on purpose (`TakePreparation.includedWindowIDs`): the video shows the wallpaper where the icons are.
/// Finder's settings are never touched.
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

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "DesktopCover")

    /// Puts a cover over the desktop of every screen, each with its wallpaper, and returns their window IDs once
    /// they are on the screen. Covers already up stay as they are.
    func show() async -> [UInt32] {
        guard covers.isEmpty else { return windowIDs }
        let started = generation
        var wallpapers: [(screen: NSScreen, displayID: UInt32, wallpaper: Wallpaper)] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            wallpapers.append((screen, displayID, await Self.wallpaper(of: displayID, on: screen)))
        }
        guard generation == started else { return [] }
        for (screen, displayID, wallpaper) in wallpapers {
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

    /// Each cover over its screen's frame now, drawn again. A cover whose screen is gone stays where it was.
    private func refit() {
        for cover in covers {
            guard let screen = Self.screen(cover.displayID) else { continue }
            cover.panel.setFrame(screen.frame, display: false)
        }
        redraw()
    }

    /// Captures each screen's wallpaper again, as the desktop now on it shows it, and draws it; a redraw still
    /// capturing is given up.
    private func redraw() {
        redrawing?.cancel()
        let covers = covers
        redrawing = Task {
            for cover in covers {
                guard let screen = Self.screen(cover.displayID) else { continue }
                let wallpaper = await Self.wallpaper(of: cover.displayID, on: screen)
                guard !Task.isCancelled else { return }
                cover.view.show(wallpaper)
            }
        }
    }

    private static func screen(_ displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    /// The wallpaper as it is seen; if it cannot be captured, its image as macOS draws it.
    private static func wallpaper(of displayID: UInt32, on screen: NSScreen) async -> Wallpaper {
        do {
            return .captured(try await WallpaperSnapshot.capture(displayID: displayID))
        } catch {
            logger.error(
                "Cannot capture the wallpaper of display \(displayID, privacy: .public), drawing its image: \(String(describing: error), privacy: .public)")
            return picture(on: screen)
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
