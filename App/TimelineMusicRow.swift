// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Export
import ProjectFormat
import QuartzCore

/// What the Music and Imported Clips rows know besides the document: what `EditorAudio` has of its files.
struct TimelineMusicInfo {
    var shown = EditorAudio.Shown()
    /// By `MusicItem.source`, and by the asset of an imported clip.
    var waveforms: [String: WaveformLevels] = [:]
}

/// A block of the Music or the Imported Clips row: its waveform, where a theme starts again, the stretch where a file
/// that does not repeat has run out, its volume line with its fades as ramps, its name and, while it is being made, how
/// far that is.
final class MusicBlockLayer: CALayer {
    let wave = CAShapeLayer()
    let hatch = CAShapeLayer()
    let marks = CAShapeLayer()
    let line = CAShapeLayer()
    let label = CATextLayer()
    let bar = CALayer()
    var labelText: String?
    var barRunning = false

    override init() {
        super.init()
        masksToBounds = true
        cornerRadius = 4
        borderWidth = 1
        hatch.lineWidth = 1
        hatch.fillColor = nil
        marks.lineWidth = 1
        marks.lineDashPattern = [2, 2]
        marks.fillColor = nil
        line.fillColor = nil
        line.lineWidth = 1.5
        line.lineJoin = .round
        TimelineText.setUp(label, size: 10, weight: .semibold)
        bar.cornerRadius = 1
        for sublayer in [wave, hatch, marks, line, label, bar] { addSublayer(sublayer) }
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// An imported clip whose sound the Imported Clips row draws (phase 3 design §7.7): one of the sequence
/// (`ClipContent.media`) or over it (`AnnotationKind.clip`), where the output plays it and from where in its file.
struct ImportedClipSound {
    var id: String
    var asset: String
    var output: Range<Int64>
    /// The file's instant at the start of `output`, in ns, and how fast it plays.
    var fileStart: Int64
    var speed: Double
    /// In dB; a muted clip annotation is −∞.
    var gain: Double

    /// The imported clips of `document` whose map is `map`, by their start.
    static func all(_ document: EditDocument, map: TimeMap) -> [ImportedClipSound] {
        var sounds: [ImportedClipSound] = []
        for (k, clip) in document.sequence.enumerated() {
            guard case let .media(media)? = clip.content, k < map.clipOutputStarts.count else { continue }
            let start = map.clipOutputStarts[k], length = TimeMap.outputDuration(of: clip)
            guard length > 0 else { continue }
            sounds.append(ImportedClipSound(
                id: clip.id, asset: media.asset, output: start..<(start + length), fileStart: media.start,
                speed: ClipSpeed.clamped(media.speed), gain: media.volume))
        }
        for annotation in document.annotations.items {
            guard case let .clip(clip) = annotation.kind, let output = TimelineAnnotationItems.range(of: annotation.id, in: document)
            else { continue }
            sounds.append(ImportedClipSound(
                id: annotation.id, asset: clip.asset, output: output, fileStart: clip.start, speed: 1,
                gain: clip.muted ? GainRange.silence : clip.volume))
        }
        return sounds.sorted { $0.output.lowerBound < $1.output.lowerBound }
    }
}

/// Draws the Music row and the Imported Clips row (`TimelineTracks` calls it inside its update, without actions; phase 3
/// design §7.2, §7.4 and §7.7; plan 3c decisions 7, 12, 13 and 15), with the rules of `MusicTrackRules`:
///
/// - **Music:** each piece where the output plays it, named (its theme, or "Imported Audio"), its file's waveform from
///   `offset` on, starting again at each of its `wraps` (a dashed mark) and hatched where a file that does not repeat has
///   run out; the fades shape the waveform and are the volume line's ramps; the line at its volume (`AudioRowGeometry`).
///   One being made says "Preparing…", with a bar of how far it is (one that moves while that is not known yet). The
///   selected one is outlined in the accent color.
/// - **Imported Clips:** each imported clip, of the sequence or over it, with the waveform of its file's sound from where
///   it plays, at its volume. It edits nothing (the clips' inspectors of 3a do).
///
/// A row the solo leaves out is dimmed, as the audio rows are.
@MainActor
final class TimelineMusicRow {
    let layer = CALayer()
    private let blocks: LayerPool<MusicBlockLayer>
    private let clips: LayerPool<MusicBlockLayer>
    /// What `EditorAudio` has of the files.
    var info = TimelineMusicInfo()
    /// Solo: the rows not in it are dimmed.
    var solo = AudioSolo()
    /// The colors, made for the palette they were made with.
    private var colors: (background: CGColor, increaseContrast: Bool, music: Colors, clips: Colors)?

    private struct Colors {
        var fill, stroke, wave, line, text, hatch: CGColor
    }

    init() {
        blocks = LayerPool(parent: layer) { MusicBlockLayer() }
        clips = LayerPool(parent: layer) { MusicBlockLayer() }
    }

    func begin() {
        blocks.begin()
        clips.begin()
    }

    func end() {
        blocks.end()
        clips.end()
    }

    func reset() {
        blocks.removeAll()
        clips.removeAll()
        colors = nil
    }

    var layerCount: Int { blocks.shownCount + clips.shownCount }

    /// The Music row of `content` at `geometry`, the ids in `selected` outlined, settling after an edit with
    /// `Motion.trackItem`.
    func layOutMusic(
        _ content: TimelineContent, _ row: TimelineGeometry.Row, _ geometry: TimelineGeometry, _ palette: TimelinePalette,
        selected: Set<String>, settling: Bool
    ) {
        layer.frame = CGRect(x: 0, y: 0, width: geometry.areaWidth, height: geometry.rowsHeight)
        let colors = colors(palette).music
        let top = row.top + 2, height = row.height - 4
        let opacity: Float = dimmed(.music, content) ? 0.5 : 1
        let items = Dictionary(content.document.music.items.map { ($0.id, $0) }) { first, _ in first }
        for block in MusicTrackRules.blocks(content.document, timeMap: content.map, lengths: info.shown.lengths) {
            guard let item = items[block.id], let rect = geometry.itemRect(block.output, top: top, height: height, gap: 1) else { continue }
            let (shape, isNew) = blocks.layer(block.id)
            if isNew { shape.label.contentsScale = geometry.backingScale }
            let isSelected = selected.contains(block.id)
            style(shape, colors, palette, selected: isSelected, opacity: opacity)
            Self.place(shape, rect, isNew: isNew, settling: settling)
            let length = info.shown.lengths[item.source]
            let local = LocalAxis(geometry: geometry, rect: rect)
            let envelope = Envelope(block: block)
            shape.wave.frame = shape.bounds
            shape.wave.path = info.waveforms[item.source].flatMap { levels in
                waveformPath(levels, local: local, height: height, from: block.output) { τ in
                    // Where the file is at output instant τ (nil: it ran out), and the volume of the fades there.
                    var at = item.offset + (τ - block.output.lowerBound)
                    if let length, length > 0 {
                        if item.loop { at %= length } else if at >= length { return nil }
                    }
                    return (at, envelope.amplitude(at: τ))
                }
            }
            // Where the theme starts again, and where a file that does not repeat has run out.
            let marks = CGMutablePath()
            for wrap in block.wraps {
                let x = local.x(wrap)
                guard x >= 0, x <= rect.width else { continue }
                marks.move(to: CGPoint(x: x, y: 0))
                marks.addLine(to: CGPoint(x: x, y: height))
            }
            shape.marks.frame = shape.bounds
            shape.marks.path = marks
            shape.hatch.frame = shape.bounds
            shape.hatch.path = block.runsOutAt.flatMap { Self.hatchPath(from: max(local.x($0), 0), to: rect.width, height: height) }
            // The volume line, its fades as ramps.
            shape.line.frame = shape.bounds
            shape.line.path = Self.volumeLine(block, local: local, height: height)
            // Its name, and how far its making is.
            let preparing = info.shown.preparing.contains(item.source)
            var text = EditorAudio.name(ofSource: item.source)
            if preparing {
                text += " · " + EditorAudio.preparingText
                if let progress = info.shown.progress { text += " " + Self.percent(progress) }
            }
            setLabel(shape, text, rect: rect, geometry: geometry, height: height)
            setBar(shape, preparing: preparing, progress: info.shown.progress, colors: colors, width: rect.width, height: height)
        }
    }

    /// The Imported Clips row of `content` at `geometry`.
    func layOutImported(
        _ content: TimelineContent, _ row: TimelineGeometry.Row, _ geometry: TimelineGeometry, _ palette: TimelinePalette,
        settling: Bool
    ) {
        layer.frame = CGRect(x: 0, y: 0, width: geometry.areaWidth, height: geometry.rowsHeight)
        let colors = colors(palette).clips
        let top = row.top + 2, height = row.height - 4
        let opacity: Float = dimmed(.importedClips, content) ? 0.5 : 1
        let (lower, upper) = geometry.visibleOutput
        for sound in ImportedClipSound.all(content.document, map: content.map)
        where sound.output.upperBound >= lower && sound.output.lowerBound <= upper {
            guard let rect = geometry.itemRect(sound.output, top: top, height: height, gap: 1) else { continue }
            let (shape, isNew) = clips.layer(sound.id)
            if isNew { shape.label.contentsScale = geometry.backingScale }
            style(shape, colors, palette, selected: false, opacity: opacity)
            Self.place(shape, rect, isNew: isNew, settling: settling)
            let local = LocalAxis(geometry: geometry, rect: rect)
            let amplitude = sound.gain <= GainRange.silence ? 0 : min(pow(10, sound.gain / 20), 2)
            shape.wave.frame = shape.bounds
            shape.wave.path = info.waveforms[sound.asset].flatMap { levels in
                waveformPath(levels, local: local, height: height, from: sound.output) { τ in
                    let at = sound.fileStart + Int64(Double(τ - sound.output.lowerBound) * sound.speed)
                    return (at, amplitude)
                }
            }
            shape.marks.path = nil
            shape.hatch.path = nil
            shape.line.path = nil
            shape.label.isHidden = true
            setBar(shape, preparing: false, progress: nil, colors: colors, width: rect.width, height: height)
        }
    }

    // MARK: - Drawing

    /// From the output to a block's own points.
    private struct LocalAxis {
        let geometry: TimelineGeometry
        let rect: CGRect

        func x(_ τ: Int64) -> Double { geometry.x(τ) - rect.minX }
        func output(atX x: Double) -> Int64 { geometry.output(atX: x + rect.minX) }
    }

    /// A piece's fades as the mix makes them (plan decision 7): smoothstep in amplitude, each at most half the piece.
    private struct Envelope {
        let block: MusicTrackRules.Block

        func amplitude(at τ: Int64) -> Double {
            var gain = 1.0
            if block.fadeIn > 0 { gain *= Self.smoothstep(Double(τ - block.output.lowerBound) / Double(block.fadeIn)) }
            if block.fadeOut > 0 { gain *= Self.smoothstep(Double(block.output.upperBound - τ) / Double(block.fadeOut)) }
            return gain
        }

        static func smoothstep(_ x: Double) -> Double {
            let x = min(max(x, 0), 1)
            return x * x * (3 - 2 * x)
        }
    }

    /// The waveform across what is in sight of a block over `output`: for each point of width, the lowest and highest
    /// sample of the file where `place` says it is (`nil`: silent) over that point, times the amplitude it gives.
    private func waveformPath(
        _ levels: WaveformLevels, local: LocalAxis, height: Double, from output: Range<Int64>,
        place: (Int64) -> (at: Int64, amplitude: Double)?
    ) -> CGPath? {
        let middle = height / 2, half = height / 2 - 3
        let first = max(0, Int(max(local.x(output.lowerBound), -local.rect.minX).rounded(.down)))
        let last = min(Int(local.rect.width.rounded(.up)), Int((local.geometry.areaWidth - local.rect.minX).rounded(.up)))
        guard last > first else { return nil }
        var tops: [CGPoint] = []
        var bottoms: [CGPoint] = []
        tops.reserveCapacity(last - first + 1)
        bottoms.reserveCapacity(last - first + 1)
        for column in first...last {
            let x = Double(column)
            let a = max(local.output(atX: x), output.lowerBound), b = min(local.output(atX: x + 1), output.upperBound)
            var low: Float = 0, high: Float = 0
            if a < b, let start = place(a), let end = place(max(b - 1, a)), start.amplitude > 0 || end.amplitude > 0 {
                // Across a wrap the file goes on from its start: both stretches (the first one to the file's end).
                let spans: [(Int64, Int64)] =
                    end.at >= start.at ? [(start.at, end.at + 1)] : [(start.at, start.at + (b - a)), (Int64(0), end.at + 1)]
                var l = Float.infinity, h = -Float.infinity
                for (from, to) in spans {
                    if let range = levels.range(fromPair: Double(from) / 1e7, toPair: Double(to) / 1e7) {
                        l = min(l, range.x)
                        h = max(h, range.y)
                    }
                }
                if l <= h {
                    let amplitude = Float(max(start.amplitude, end.amplitude))
                    low = min(max(l * amplitude, -1), 1)
                    high = min(max(h * amplitude, -1), 1)
                }
            }
            let topY = middle - Double(high) * half, bottomY = max(middle - Double(low) * half, topY + 0.5)
            tops.append(CGPoint(x: x, y: topY))
            bottoms.append(CGPoint(x: x, y: bottomY))
        }
        let path = CGMutablePath()
        path.addLines(between: tops + bottoms.reversed())
        path.closeSubpath()
        return path
    }

    /// A piece's volume line: from the bottom up to its volume over its fade in, there until its fade out, and down.
    private static func volumeLine(_ block: MusicTrackRules.Block, local: LocalAxis, height: Double) -> CGPath {
        let y = min(max(AudioRowGeometry.y(ofGain: block.gain, height: height), 0.75), height - 0.75)
        let bottom = height - 0.75
        let path = CGMutablePath()
        path.move(to: CGPoint(x: local.x(block.output.lowerBound), y: block.fadeIn > 0 ? bottom : y))
        path.addLine(to: CGPoint(x: local.x(block.output.lowerBound + block.fadeIn), y: y))
        path.addLine(to: CGPoint(x: local.x(block.output.upperBound - block.fadeOut), y: y))
        path.addLine(to: CGPoint(x: local.x(block.output.upperBound), y: block.fadeOut > 0 ? bottom : y))
        return path
    }

    /// Diagonal lines from `x` to `right`: where the file has run out.
    private static func hatchPath(from x: Double, to right: Double, height: Double) -> CGPath? {
        guard right > x else { return nil }
        let path = CGMutablePath()
        var at = x - height
        while at < right {
            path.move(to: CGPoint(x: max(at, x), y: height - max(x - at, 0)))
            path.addLine(to: CGPoint(x: min(at + height, right), y: max(height - (min(at + height, right) - at), 0)))
            at += 6
        }
        return path
    }

    private func style(_ shape: MusicBlockLayer, _ colors: Colors, _ palette: TimelinePalette, selected: Bool, opacity: Float) {
        shape.backgroundColor = colors.fill
        shape.borderColor = selected ? palette.selection : (palette.increaseContrast ? palette.contrastBorder : colors.stroke)
        shape.borderWidth = selected ? 2 : 1
        shape.wave.fillColor = colors.wave
        shape.marks.strokeColor = colors.stroke
        shape.hatch.strokeColor = colors.hatch
        shape.line.strokeColor = palette.increaseContrast ? palette.contrastBorder : colors.line
        shape.label.foregroundColor = colors.text
        shape.bar.backgroundColor = palette.selection
        shape.opacity = opacity
    }

    /// The block's name at its top left, in sight when the block starts left of the area.
    private func setLabel(_ shape: MusicBlockLayer, _ text: String, rect: CGRect, geometry: TimelineGeometry, height: Double) {
        if shape.labelText != text {
            shape.labelText = text
            shape.label.string = text
        }
        let x = max(4, -rect.minX + 4)
        let width = max(rect.width - x - 4, 0)
        shape.label.isHidden = width < 24
        shape.label.frame = CGRect(x: x, y: 2, width: width, height: 13)
    }

    /// The bar under a block being made: as long as its progress, or a piece of it that comes and goes while that is not
    /// known (a fade with Reduce Motion).
    private func setBar(_ shape: MusicBlockLayer, preparing: Bool, progress: Double?, colors: Colors, width: Double, height: Double) {
        shape.bar.isHidden = !preparing
        guard preparing else {
            if shape.barRunning {
                shape.bar.removeAllAnimations()
                shape.barRunning = false
            }
            return
        }
        if let progress {
            if shape.barRunning {
                shape.bar.removeAllAnimations()
                shape.barRunning = false
            }
            shape.bar.frame = CGRect(x: 0, y: height - 3, width: width * min(max(progress, 0), 1), height: 3)
            return
        }
        let piece = max(min(width * 0.3, 80), 12)
        shape.bar.frame = CGRect(x: 0, y: height - 3, width: piece, height: 3)
        guard !shape.barRunning else { return }
        shape.barRunning = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 4 * Motion.reducedMotionFade.timeInterval
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            shape.bar.add(pulse, forKey: "preparing")
        } else {
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = -piece / 2
            slide.toValue = width + piece / 2
            slide.duration = 1.4
            slide.repeatCount = .infinity
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.bar.add(slide, forKey: "preparing")
        }
    }

    /// "42 %".
    private static func percent(_ fraction: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: min(max(fraction, 0), 1))) ?? ""
    }

    /// Whether the preview's solo leaves `row` out (as `EditorModel.soloDocument(of:)` hears it: a solo of rows no
    /// longer shown is none).
    private func dimmed(_ row: AudioRowID, _ content: TimelineContent) -> Bool {
        guard !solo.isEmpty else { return false }
        let soloed = solo.rows.intersection(content.layout.tracks.compactMap { TrackHeaderView.soloRow($0.track) })
        return !soloed.isEmpty && !soloed.contains(row)
    }

    /// The music's indigo and the imported clips' brown, in the row's light or dark.
    private func colors(_ palette: TimelinePalette) -> (music: Colors, clips: Colors) {
        if let colors, colors.background == palette.background, colors.increaseContrast == palette.increaseContrast {
            return (colors.music, colors.clips)
        }
        let background = NSColor(cgColor: palette.background)?.usingColorSpace(.sRGB) ?? .black
        let dark = background.brightnessComponent < 0.5
        let ink = dark ? NSColor.white : NSColor.black
        func make(_ hue: NSColor) -> Colors {
            let resolved = hue.usingColorSpace(.sRGB) ?? hue
            let text = dark ? resolved.blended(withFraction: 0.6, of: .white) ?? .white : resolved.blended(withFraction: 0.5, of: .black) ?? .black
            return Colors(
                fill: resolved.withAlphaComponent(dark ? 0.16 : 0.12).cgColor, stroke: resolved.withAlphaComponent(dark ? 0.42 : 0.45).cgColor,
                wave: resolved.withAlphaComponent(dark ? 0.85 : 0.75).cgColor, line: ink.withAlphaComponent(dark ? 0.85 : 0.72).cgColor,
                text: text.cgColor, hatch: ink.withAlphaComponent(dark ? 0.22 : 0.18).cgColor)
        }
        let made = (music: make(.systemIndigo), clips: make(.systemBrown))
        colors = (palette.background, palette.increaseContrast, made.music, made.clips)
        return made
    }

    /// Puts `layer` at `rect`; settling, it goes there from where it was with `Motion.trackItem`.
    private static func place(_ layer: CALayer, _ rect: CGRect, isNew: Bool, settling: Bool) {
        let from = layer.presentation()?.frame ?? layer.frame
        layer.frame = rect
        guard settling, !isNew, from != rect, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let move = CASpringAnimation(keyPath: "position", spring: Motion.trackItem)
        move.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
        move.toValue = NSValue(point: CGPoint(x: rect.midX, y: rect.midY))
        let grow = CASpringAnimation(keyPath: "bounds", spring: Motion.trackItem)
        grow.fromValue = NSValue(rect: CGRect(origin: .zero, size: from.size))
        grow.toValue = NSValue(rect: CGRect(origin: .zero, size: rect.size))
        layer.add(move, forKey: "settleMove")
        layer.add(grow, forKey: "settleSize")
    }
}

// MARK: - What is under the pointer

/// The Music track pointed at: what is there (`MusicTrackRules.hit`) and the output time there.
struct MusicPointed {
    var hit: MusicTrackHit
    var output: Int64
}

extension EditorTimelineView {
    /// The pieces of music as the Music row draws them, with the lengths `EditorAudio` has.
    var musicBlocks: [MusicTrackRules.Block] {
        guard let content else { return [] }
        return MusicTrackRules.blocks(content.document, timeMap: content.map, lengths: tracks.musicRow.info.shown.lengths)
    }

    /// The Music row's blocks' area (its top in the view's coordinates and its height), where their volume lines are
    /// drawn; `nil` without the row.
    func musicRowArea() -> (top: Double, height: Double)? {
        guard let geometry = geometry(), let row = geometry.rows.first(where: { $0.track == .music }) else { return nil }
        return (TimelineLayout.rulerHeight + row.top + 2 - geometry.verticalOffset, row.height - 4)
    }

    /// What is at `point` (the view's coordinates) of the Music row, with ⌥ (`option`) or without; `nil` off it.
    func musicHit(at point: CGPoint, option: Bool) -> MusicPointed? {
        guard let geometry = geometry(), let area = musicRowArea(), point.x >= TimelineLayout.headerWidth,
            point.y >= area.top - 2, point.y < area.top + area.height + 2
        else { return nil }
        let x = point.x - TimelineLayout.headerWidth
        let spans = musicBlocks.map { ($0, x: geometry.x($0.output.lowerBound)...geometry.x($0.output.upperBound)) }
        let hit = MusicTrackRules.hit(x: x, y: point.y - area.top, option: option, height: area.height, blocks: spans)
        return MusicPointed(hit: hit, output: geometry.output(atX: x))
    }
}
