// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import Editing
import Export
import Foundation
import ProjectFormat
import SwiftUI

extension EditorModel {
    /// The showcase of the sound, a track per app, the ranges, the J and L cuts, the music and its ducking (3c): what its
    /// `TOMA_SHOWCASE_P3_*` variables ask for.
    ///
    /// - `TOMA_SHOWCASE_P3_AUDIO=rows` (U11): the take cut in two clips (if it is one), a stretch at −6 dB on the
    ///   microphone from 1 s to 3 s, a J cut of −0,3 s at the second clip, Solo on the microphone and the stretch selected.
    /// - `TOMA_SHOWCASE_P3_AUDIO=music` (U12): what `rows` does, then Calm over the whole video, selected (with
    ///   `TOMA_SHOWCASE_TAB=5`, the Audio tab shows it). `music-file` the same with an imported file instead of Calm, if
    ///   `TOMA_SHOWCASE_P3_AUDIO_FILE=<path>` names one.
    /// - `TOMA_SHOWCASE_P3_AUDIO=library` (U12): the Audio tab with the library's list open over "Add Music…";
    ///   `library-listen` the same, hearing Focus (made first if it is not in the cache: "Preparing…").
    /// - With `music` and `TOMA_SHOWCASE_P3_TIMELINE_PNG=<path>`: `<path>-preparing.png` of the timeline at once, then
    ///   `<path>` once the theme is made and its waveform is drawn (up to 4 minutes: a Debug build makes a theme slowly),
    ///   over the one the annotations' showcase wrote before; with `TOMA_SHOWCASE_PANEL_PNG=<path>`, the window and the
    ///   panel then too (`CaptionsShowcase.snapshotLater`). With `library`, `<TOMA_SHOWCASE_PANEL_PNG>-library.png` of the
    ///   list.
    func showcaseAudio(_ environment: [String: String]) async {
        switch environment["TOMA_SHOWCASE_P3_AUDIO"] {
        case "rows"?:
            showcaseAudioRows()
        case let variant? where variant.hasPrefix("music"):
            showcaseAudioRows()
            if variant == "music-file", let file = environment["TOMA_SHOWCASE_P3_AUDIO_FILE"] {
                importMusic(URL(filePath: file), atOutput: 0)
                try? await Task.sleep(for: .seconds(2))
            } else if !addMusic(source: MusicThemes.source("calm"), atOutput: 0), let first = document?.music.items.first {
                // A project the showcase already put music in: that one.
                selection = .musicItem(first.id)
            }
            await showcaseMusicSnapshots(environment)
        case let variant? where variant.hasPrefix("library"):
            panelTab = .audio
            try? await Task.sleep(for: .seconds(1))
            // The list as the timeline's "Add Music…" opens it, over the middle of the timeline.
            if let timeline = Self.timelineView() {
                timeline.interaction.showMusicLibrary(at: CGPoint(x: timeline.bounds.midX, y: 40), replacing: nil)
            }
            if variant == "library-listen" { audio.listen(to: "focus") }
            if let path = environment["TOMA_SHOWCASE_PANEL_PNG"] {
                try? await Task.sleep(for: .seconds(2))
                if !Self.writePopoverPNG(to: URL(filePath: "\(path)-library.png")) {
                    // The list drawn in a window of its own, as the popover shows it.
                    await writeLibraryPNG(to: URL(filePath: "\(path)-library.png"))
                }
            }
        default:
            break
        }
    }

    private func showcaseAudioRows() {
        guard let document, let microphone = audioTracks.first(where: \.isMicrophone) ?? audioTracks.first else { return }
        let duration = TimeMap(sequence: document.sequence).duration
        if document.sequence.count == 1, let step = SequenceCommands.split(document, atOutput: duration / 2, makeID: Self.newID) {
            perform(step)
        }
        addGainRange(track: microphone.track, forOutput: 1_000_000_000..<3_000_000_000, gain: -6)
        let selected = selection
        setAudioShift(clip: 1, to: -300_000_000)
        toggleSolo(.track(microphone.track))
        selection = selected
    }

    /// The timeline (and the window) as `showcaseAudio` says, while the music is made and once it is drawn.
    private func showcaseMusicSnapshots(_ environment: [String: String]) async {
        let timeline = environment["TOMA_SHOWCASE_P3_TIMELINE_PNG"]
        if let timeline {
            try? await Task.sleep(for: .seconds(1.5))
            Self.writeTimelinePNG(to: URL(filePath: timeline.replacingOccurrences(of: ".png", with: "") + "-preparing.png"))
        }
        let deadline = ContinuousClock.now + .seconds(240)
        let sources = Set(document?.music.items.map(\.source) ?? [])
        while ContinuousClock.now < deadline,
            !audio.shown.preparing.isDisjoint(with: sources) || sources.contains(where: { audio.waveforms[$0] == nil })
        {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(1))
        if let timeline { Self.writeTimelinePNG(to: URL(filePath: timeline)) }
        if environment["TOMA_SHOWCASE_PANEL_PNG"] != nil { CaptionsShowcase.snapshotLater(window) }
    }

    /// The first editor timeline of the app's windows, drawn from its layers into a PNG at `url` (as the annotations'
    /// showcase draws it).
    private static func timelineView() -> EditorTimelineView? {
        func timeline(in view: NSView) -> EditorTimelineView? {
            if let found = view as? EditorTimelineView { return found }
            for subview in view.subviews { if let found = timeline(in: subview) { return found } }
            return nil
        }
        return NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(timeline(in:)) }).first
    }

    private static func writeTimelinePNG(to url: URL) {
        guard let view = timelineView(), let layer = view.layer,
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = 2.0
        // Every row, the Music row last: the view as tall as its rows for the drawing, then as it was.
        let frame = view.frame
        let rows = view.content?.layout.tracks.reduce(0) { $0 + $1.height } ?? 0
        defer {
            view.frame = frame
            view.layoutSubtreeIfNeeded()
        }
        if rows > view.bounds.height {
            view.frame.size.height = rows
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1,
            let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The library's list in a window of its own (when the popover cannot be found), drawn into a PNG at `url`.
    private func writeLibraryPNG(to url: URL) async {
        let host = NSHostingView(rootView: MusicLibraryPicker(model: self, replacing: nil))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        try? await Task.sleep(for: .seconds(1))
        _ = Self.writeViewPNG(host, to: url)
        window.orderOut(nil)
    }

    /// The window of the popover open (the library's list), drawn by its views into a PNG at `url`; whether there was one.
    private static func writePopoverPNG(to url: URL) -> Bool {
        guard let window = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }),
            let view = window.contentView
        else { return false }
        return writeViewPNG(view, to: url)
    }

    /// `view` drawn by itself over the window's background into a PNG at `url`.
    private static func writeViewPNG(_ view: NSView, to url: URL) -> Bool {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.displayIgnoringOpacity(view.bounds, in: context)
        }
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }
}
#endif
