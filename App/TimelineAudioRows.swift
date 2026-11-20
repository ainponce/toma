// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat
import QuartzCore

/// A clip's sound where the output plays it (phase 3 design §7.3): `[audioStarts[k], audioStarts[k + 1])`, so a J or
/// an L cut moves it off the picture's clip.
struct AudioWindowInfo {
    /// The clip's index in the sequence.
    var clip: Int
    /// Nothing of it is heard: a clip with content (the mix makes it silent, `EditedMix`), or one faster than 4× (the
    /// export's `SpeedStretch.maximumSpeed`).
    var silent: Bool
}

/// What the audio rows show of one revision of the document, besides each track's gain (`TimelineContent.audio`).
enum TimelineAudioItems {
    /// Clips faster than this are silent: their waveform is flat.
    static let fastestHeard = 4.0

    /// The sound of each clip of `sequence` that lasts any output, where `map` plays it: from its `audioStarts` to the
    /// next clip's (the end of the output for the last), cut to the output.
    static func windows(_ sequence: [Clip], map: TimeMap) -> TrackItems<AudioWindowInfo> {
        guard map.audioStarts.count == sequence.count else { return TrackItems([]) }
        var items: [TrackItems<AudioWindowInfo>.Item] = []
        for k in sequence.indices where TimeMap.outputDuration(of: sequence[k]) > 0 {
            let lower = min(max(map.audioStarts[k], 0), map.duration)
            let upper = min(max(k + 1 < sequence.count ? map.audioStarts[k + 1] : map.duration, 0), map.duration)
            guard lower < upper else { continue }
            let clip = sequence[k]
            let silent = clip.content != nil || ClipSpeed.clamped(clip.speed) > fastestHeard
            items.append(.init(id: clip.id, output: lower..<upper, info: AudioWindowInfo(clip: k, silent: silent)))
        }
        return TrackItems(items)
    }

    /// "−6 dB", "+3,5 dB", "0 dB" or "−∞ dB": a gain as the capsule, the labels and VoiceOver say it.
    @MainActor
    static func gainText(_ dB: Double) -> String {
        guard let number = AudioRowText.decibels(dB, locale: .current) else {
            return String(localized: "−∞ dB", comment: "A volume of an audio row of the timeline: silence (minus infinity decibels)")
        }
        return String(format: String(localized: "%@ dB", comment: "A volume of an audio row of the timeline, in decibels: «−6 dB»"), number)
    }

    /// "J Cut" or "L Cut", with how far the sound moved: what the drag of a cut of the sound says.
    @MainActor
    static func cutText(_ shift: Int64) -> String {
        let amount = AudioRowText.shift(shift, locale: .current)
        switch AudioRowText.cut(shift) {
        case .j?: return String(localized: "J Cut", comment: "The cut of the sound moved before the picture's: the next clip is heard sooner") + " · " + amount
        case .l?: return String(localized: "L Cut", comment: "The cut of the sound moved after the picture's: the clip before is heard longer") + " · " + amount
        case nil: return amount
        }
    }
}

/// A cut of the sound moved off the picture's (a J or L cut): a line where the sound cuts and a tab with its letter over
/// it.
final class AudioCutLayer: CALayer {
    let line = CALayer()
    let tab = CATextLayer()
    var letter: String?

    override init() {
        super.init()
        tab.cornerRadius = 3
        tab.alignmentMode = .center
        TimelineText.setUp(tab, size: 9, weight: .bold)
        addSublayer(line)
        addSublayer(tab)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Draws the audio rows (`TimelineTracks` calls it inside its update, without actions; phase 3 design §7.2 and §7.3):
/// for each clip in sight, a region where its sound plays and its waveform from the source that sound reads (so a J or
/// an L cut moves both off the picture's clip), scaled by the volume line; the stretches at another volume, the one
/// selected outlined in the accent color; the volume line over the waveform (`AudioRowGeometry`); the stretch a drag
/// marked, dashed; the notch of each cut of the sound moved, "J" or "L"; and the capsule with the volume of the stretch
/// marked or selected. A row the solo leaves out, like a muted one, is dimmed: the preview does not let it be heard.
@MainActor
final class TimelineAudioRows {
    /// The id the marked stretch has where the hits look for it (`AudioRowRules.hit`): never a stretch's (`g-…`).
    static let markID = ""

    /// The rows' layers, over the rows' whole area (a sublayer of the rows, scrolled with them): under the waveforms and
    /// the lines, the regions and the stretches; over them, the mark, the notches and the capsule.
    let layer = CALayer()
    private let under = CALayer()
    private let over = CALayer()
    private let regions: LayerPool<CALayer>
    private let bands: LayerPool<CALayer>
    private let notches: LayerPool<AudioCutLayer>
    private var waveforms: [String: CAShapeLayer] = [:]
    private var lines: [String: CAShapeLayer] = [:]
    private let markLayer = CAShapeLayer()
    private let capsule = CATextLayer()
    /// The rows laid out in this pass, and whether the mark and the capsule were.
    private var laidOut: Set<String> = []
    private var markShown = false
    private var capsuleShown = false
    /// The colors of the stretches and the line, made for the palette they were made with.
    private var colors: (background: CGColor, increaseContrast: Bool, fill: CGColor, edge: CGColor, line: CGColor)?

    /// The stretch a drag over a waveform marked (plan decision 13), on the sequence it was marked on: only here, never in
    /// the document, until its first change makes it. Another sequence (an edit) drops it.
    var mark: (track: String, output: Range<Int64>, sequence: [Clip])?
    /// Solo: the rows not in it are dimmed.
    var solo = AudioSolo()
    /// The clip whose cut of the sound is being dragged: its notch is drawn even at 0, and follows with `Motion.trackItem`.
    var draggedCut: Int?
    /// Where the capsule is after the last layout, in the rows' coordinates, and what it is of: a stretch (`range`) or the
    /// marked one (`nil`).
    private(set) var capsuleSpot: (frame: CGRect, track: String, range: String?)?

    init() {
        layer.addSublayer(under)
        layer.addSublayer(over)
        regions = LayerPool(parent: under) {
            let region = CALayer()
            region.cornerRadius = 4
            region.borderWidth = 1
            return region
        }
        bands = LayerPool(parent: under) {
            let band = CALayer()
            band.cornerRadius = 3
            // Over the regions.
            band.zPosition = 1
            return band
        }
        over.addSublayer(markLayer)
        notches = LayerPool(parent: over) {
            let notch = AudioCutLayer()
            notch.zPosition = 1
            return notch
        }
        markLayer.lineWidth = 1
        markLayer.lineDashPattern = [3, 2]
        capsule.cornerRadius = 4
        capsule.alignmentMode = .center
        capsule.zPosition = 2
        TimelineText.setUp(capsule, size: 10, weight: .semibold, monospacedDigits: true)
        over.addSublayer(capsule)
    }

    /// Starts a pass of `TimelineTracks.update`; what is not laid out by its end is hidden (the row may be gone).
    func begin() {
        regions.begin()
        bands.begin()
        notches.begin()
        laidOut = []
        markShown = false
        capsuleShown = false
    }

    func end() {
        regions.end()
        bands.end()
        notches.end()
        for (id, shape) in waveforms where !laidOut.contains(id) {
            shape.removeFromSuperlayer()
            waveforms[id] = nil
        }
        for (id, line) in lines where !laidOut.contains(id) {
            line.removeFromSuperlayer()
            lines[id] = nil
        }
        markLayer.isHidden = !markShown
        capsule.isHidden = !capsuleShown
        if !capsuleShown { capsuleSpot = nil }
    }

    /// Forgets the layers and the colors (the appearance changed).
    func reset() {
        regions.removeAll()
        bands.removeAll()
        notches.removeAll()
        for shape in Array(waveforms.values) + Array(lines.values) { shape.removeFromSuperlayer() }
        waveforms = [:]
        lines = [:]
        colors = nil
    }

    var layerCount: Int { regions.shownCount + bands.shownCount + notches.shownCount + waveforms.count + lines.count }

    /// Audio row `id` of `content` at `geometry`, with its waveform's `levels` in each take, by take id (none yet: no
    /// waveform of that take), the ids in `selected` outlined, and settling into place after an edit with
    /// `Motion.trackItem`.
    func layOut(
        _ id: String, _ content: TimelineContent, _ row: TimelineGeometry.Row, _ geometry: TimelineGeometry,
        _ palette: TimelinePalette, levels: (String) -> WaveformLevels?, selected: Set<String>, settling: Bool
    ) {
        layer.frame = CGRect(x: 0, y: 0, width: geometry.areaWidth, height: geometry.rowsHeight)
        under.frame = layer.bounds
        over.frame = layer.bounds
        laidOut.insert(id)
        let colors = colors(palette)
        let track = content.audio[id]
        let isMicrophone = track?.isMicrophone != false
        let tint = isMicrophone ? palette.microphoneClip : palette.systemAudioClip
        let top = row.top + 2, height = row.height - 4
        // As the preview's mix hears it (`EditorModel.soloDocument(of:)`): a solo of rows no longer shown is none.
        let soloed = solo.isEmpty ? [] : solo.rows.intersection(content.layout.tracks.compactMap { TrackHeaderView.soloRow($0.track) })
        let silenced = track?.muted == true || (!soloed.isEmpty && !soloed.contains(.track(id)))
        let opacity: Float = silenced ? 0.5 : 1
        let (lower, upper) = geometry.visibleOutput

        // A region where each clip's sound plays.
        content.audioWindows.forEach(from: lower, to: upper) { item in
            guard let rect = geometry.itemRect(item.output, top: top, height: height, gap: 1) else { return }
            let (region, isNew) = regions.layer("\(id) \(item.id)")
            if isNew {
                region.backgroundColor = tint.fill
                region.borderColor = palette.increaseContrast ? palette.contrastBorder : tint.stroke
            }
            region.opacity = opacity
            Self.place(region, rect, isNew: isNew, settling: settling)
        }

        // The stretches at another volume, under the waveform.
        let ranges = content.audioRanges[id] ?? []
        for (n, range) in ranges.enumerated() where range.output.upperBound >= lower && range.output.lowerBound <= upper {
            guard let rect = geometry.itemRect(range.output, top: top, height: height, gap: 0) else { continue }
            let (band, isNew) = bands.layer("\(id) \(range.id) \(n)")
            let isSelected = selected.contains(range.id)
            band.backgroundColor = isSelected ? palette.selection.copy(alpha: 0.22) : colors.fill
            band.borderColor = isSelected ? palette.selection : (palette.increaseContrast ? palette.contrastBorder : colors.edge)
            band.borderWidth = isSelected ? 1.5 : 1
            band.opacity = opacity
            Self.place(band, rect, isNew: isNew, settling: settling)
        }

        // The waveform, then the volume line over it.
        let shape = waveforms[id] ?? {
            let shape = CAShapeLayer()
            layer.insertSublayer(shape, below: over)
            waveforms[id] = shape
            return shape
        }()
        shape.fillColor = isMicrophone ? palette.microphone : palette.systemAudio
        shape.opacity = opacity
        shape.frame = CGRect(x: 0, y: top, width: geometry.areaWidth, height: height)
        shape.path = waveformPath(track, levels: levels, content: content, geometry: geometry, height: height, ranges: ranges)
        let line = lines[id] ?? {
            let line = CAShapeLayer()
            line.fillColor = nil
            line.lineWidth = 1.5
            line.lineJoin = .round
            layer.insertSublayer(line, below: over)
            lines[id] = line
            return line
        }()
        line.strokeColor = palette.increaseContrast ? palette.contrastBorder : colors.line
        line.opacity = opacity
        line.frame = CGRect(x: 0, y: top, width: geometry.areaWidth, height: height)
        let rowGain = AudioRowGeometry.decibels(ofTrackGain: track?.gain ?? 1)
        line.path = Self.volumeLine(rowGain: rowGain, ranges: ranges, geometry: geometry, height: height, duration: content.map.duration)

        // The marked stretch, until an edit changes the sequence it was marked on.
        if let mark, mark.track == id {
            if mark.sequence != content.sequence {
                self.mark = nil
            } else if let rect = geometry.itemRect(mark.output, top: top, height: height, gap: 0) {
                markLayer.frame = rect
                markLayer.path = CGPath(
                    roundedRect: CGRect(origin: .zero, size: rect.size).insetBy(dx: 0.5, dy: 0.5), cornerWidth: 2.5, cornerHeight: 2.5,
                    transform: nil)
                markLayer.strokeColor = palette.selection
                markLayer.fillColor = palette.selection.copy(alpha: 0.12)
                markShown = true
            }
        }

        // The notch of each cut of the sound moved off the picture's.
        for cut in content.audioCuts where cut.audio != cut.picture || cut.clip == draggedCut {
            let x = geometry.snapped(geometry.x(cut.audio))
            guard x > -8, x < geometry.areaWidth + 8 else { continue }
            let (notch, isNew) = notches.layer("\(id) \(cut.clip)")
            if isNew {
                notch.line.backgroundColor = palette.selection
                notch.tab.backgroundColor = palette.selection
                notch.tab.foregroundColor = palette.dragLabelText
                notch.tab.contentsScale = geometry.backingScale
                notch.letter = nil
            }
            let letter: String? = switch AudioRowText.cut(cut.audio - cut.picture) {
            case .j?: "J"
            case .l?: "L"
            case nil: nil
            }
            if notch.letter != letter {
                notch.letter = letter
                notch.tab.string = letter
            }
            notch.tab.isHidden = letter == nil
            let rect = CGRect(x: x - 6, y: top, width: 12, height: height)
            Self.place(notch, rect, isNew: isNew, settling: settling || cut.clip == draggedCut)
            notch.line.frame = CGRect(x: 5.25, y: 0, width: 1.5, height: height)
            notch.tab.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        }

        // The capsule: over the marked stretch ("0 dB"), or over the selected one with its volume.
        var target: (output: Range<Int64>, gain: Double, range: String?)?
        if let mark, mark.track == id, markShown { target = (mark.output, 0, nil) }
        if target == nil, let range = ranges.first(where: { selected.contains($0.id) && $0.output.upperBound >= lower && $0.output.lowerBound <= upper }) {
            target = (range.output, range.gain, range.id)
        }
        if let target, let rect = geometry.itemRect(target.output, top: top, height: height, gap: 0) {
            let text = TimelineAudioItems.gainText(target.gain)
            if capsule.string as? String != text { capsule.string = text }
            capsule.backgroundColor = palette.dragLabelFill
            capsule.foregroundColor = palette.dragLabelText
            capsule.contentsScale = geometry.backingScale
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)]
            let width = (text as NSString).size(withAttributes: attributes).width.rounded(.up) + 12
            let visible = rect.intersection(CGRect(x: 0, y: rect.minY, width: geometry.areaWidth, height: rect.height))
            let middle = visible.isNull ? rect.midX : visible.midX
            let x = min(max(middle - width / 2, 2), max(geometry.areaWidth - width - 2, 2))
            // Under the stretch's line, or over it when the line is too low for that.
            let lineY = top + AudioRowGeometry.y(ofGain: target.gain, height: height)
            let y = lineY + 3 + 15 <= top + height ? lineY + 3 : max(lineY - 18, top)
            let frame = CGRect(x: x, y: y, width: width, height: 15)
            capsule.frame = frame
            capsuleSpot = (frame, id, target.range)
            capsuleShown = true
        }
    }

    // MARK: - Drawing

    /// The waveform across what is in sight: for each point of width, the lowest and highest sample of the source the
    /// sound plays there (`TimeMap.audioSource(ofClip:atOutput:)` in the clip's window: a J or L cut reads outside the
    /// clip), in the waveform of the clip's own take (3d), times the volume there (the track's gain, and a stretch's), and
    /// flat where nothing is heard (a muted track, a clip with content or faster than 4×, a take without the track or
    /// whose waveform is not there yet). None while no take that recorded the track has its waveform.
    private func waveformPath(
        _ track: TimelineContent.AudioTrack?, levels: (String) -> WaveformLevels?, content: TimelineContent,
        geometry: TimelineGeometry, height: Double, ranges: [AudioRangeCommands.ShownRange]
    ) -> CGPath? {
        guard let track else { return nil }
        // Each take's waveform and the host time of its pair 0.
        var waves: [String: (levels: WaveformLevels, origin: Double)] = [:]
        for (take, origin) in track.origins {
            if let found = levels(take) { waves[take] = (found, Double(origin)) }
        }
        guard !waves.isEmpty else { return nil }
        var lastClip = -1
        var wave: (levels: WaveformLevels, origin: Double)?
        let rowGain = track.muted ? 0 : min(max(track.gain, 0), 2)
        // Inside the regions, clear of their borders.
        let middle = height / 2, half = height / 2 - 3
        let windows = content.audioWindows.items
        let map = content.map
        let columns = Int(geometry.areaWidth.rounded(.up))
        var tops: [CGPoint] = []
        var bottoms: [CGPoint] = []
        tops.reserveCapacity(columns + 1)
        bottoms.reserveCapacity(columns + 1)
        var k = 0, r = 0
        let duration = map.duration
        for column in 0...columns {
            let x = Double(column)
            let a = geometry.output(atX: x), b = geometry.output(atX: x + 1)
            guard b > 0, a < duration else { continue }
            let from = max(a, 0), to = min(b, duration)
            while k < windows.count, windows[k].output.upperBound <= from { k += 1 }
            var low = Float.infinity, high = -Float.infinity
            var j = k
            while j < windows.count, windows[j].output.lowerBound < to {
                let window = windows[j]
                let start = max(from, window.output.lowerBound), end = min(to, window.output.upperBound)
                if window.info.clip != lastClip {
                    lastClip = window.info.clip
                    wave = content.sequence.indices.contains(lastClip) ? waves[content.sequence[lastClip].take] : nil
                }
                if !window.info.silent, start < end, let wave {
                    let sa = Double(map.audioSource(ofClip: window.info.clip, atOutput: start)) - wave.origin
                    let sb = Double(map.audioSource(ofClip: window.info.clip, atOutput: end)) - wave.origin
                    if let range = wave.levels.range(fromPair: sa / 1e7, toPair: sb / 1e7) {
                        low = min(low, range.x)
                        high = max(high, range.y)
                    }
                }
                j += 1
            }
            if low > high { (low, high) = (0, 0) }
            // The volume in the middle of the column: the track's, times a stretch's.
            let τ = from + (to - from) / 2
            while r < ranges.count, ranges[r].output.upperBound <= τ { r += 1 }
            var gain = rowGain
            if r < ranges.count, ranges[r].output.contains(τ) {
                gain *= ranges[r].gain <= GainRange.silence ? 0 : pow(10, ranges[r].gain / 20)
            }
            low = min(max(low * Float(gain), -1), 1)
            high = min(max(high * Float(gain), -1), 1)
            // At least half a point, so silence is a line.
            let topY = middle - Double(high) * half, bottomY = max(middle - Double(low) * half, topY + 0.5)
            tops.append(CGPoint(x: x, y: topY))
            bottoms.append(CGPoint(x: x, y: bottomY))
        }
        guard !tops.isEmpty else { return nil }
        let path = CGMutablePath()
        path.addLines(between: tops + bottoms.reversed())
        path.closeSubpath()
        return path
    }

    /// The volume line of a row `height` tall over the output (`AudioRowGeometry.y(ofGain:height:)`): at the track's
    /// `rowGain` dB, and at each stretch's own over it, with a step at its edges.
    private static func volumeLine(
        rowGain: Double, ranges: [AudioRangeCommands.ShownRange], geometry: TimelineGeometry, height: Double, duration: Int64
    ) -> CGPath? {
        let left = max(geometry.x(0), -2), right = min(geometry.x(duration), geometry.areaWidth + 2)
        guard right > left else { return nil }
        func y(_ dB: Double) -> Double { min(max(AudioRowGeometry.y(ofGain: dB, height: height), 0.75), height - 0.75) }
        let rowY = y(rowGain)
        var steps: [(from: Double, to: Double, y: Double)] = []
        var x = left
        for range in ranges {
            let a = min(max(geometry.x(range.output.lowerBound), left), right)
            let b = min(max(geometry.x(range.output.upperBound), left), right)
            guard b > a, b > x else { continue }
            if a > x { steps.append((x, a, rowY)) }
            steps.append((max(a, x), b, y(range.gain)))
            x = b
        }
        if right > x { steps.append((x, right, rowY)) }
        guard let first = steps.first else { return nil }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: first.from, y: first.y))
        for step in steps {
            path.addLine(to: CGPoint(x: step.from, y: step.y))
            path.addLine(to: CGPoint(x: step.to, y: step.y))
        }
        return path
    }

    /// The stretches' wash and edge and the volume line, in the row's light or dark.
    private func colors(_ palette: TimelinePalette) -> (fill: CGColor, edge: CGColor, line: CGColor) {
        if let colors, colors.background == palette.background, colors.increaseContrast == palette.increaseContrast {
            return (colors.fill, colors.edge, colors.line)
        }
        let background = NSColor(cgColor: palette.background)?.usingColorSpace(.sRGB) ?? .black
        let dark = background.brightnessComponent < 0.5
        let ink = dark ? NSColor.white : NSColor.black
        let made = (
            fill: ink.withAlphaComponent(dark ? 0.10 : 0.07).cgColor, edge: ink.withAlphaComponent(dark ? 0.32 : 0.28).cgColor,
            line: ink.withAlphaComponent(dark ? 0.85 : 0.72).cgColor)
        colors = (palette.background, palette.increaseContrast, made.fill, made.edge, made.line)
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

/// An audio row pointed at: its track, what is there (`AudioRowRules.hit`) and the output time there.
struct AudioRowPointed {
    var track: String
    var hit: AudioRowHit
    var output: Int64
}

extension EditorTimelineView {
    /// The waveform's area of audio row `track` (its top in the view's coordinates and its height), where its volume line
    /// is drawn; `nil` if it has no row.
    func audioRowArea(_ track: String) -> (top: Double, height: Double)? {
        guard let geometry = geometry(), let row = geometry.rows.first(where: { $0.track == .audio(id: track) }) else { return nil }
        return (TimelineLayout.rulerHeight + row.top + 2 - geometry.verticalOffset, row.height - 4)
    }

    /// What is at `point` (the view's coordinates) of the audio row there, with ⌥ (`option`) or without; `nil` off the
    /// audio rows. The marked stretch is a stretch at 0 dB (`TimelineAudioRows.markID`), before the others; a cut is
    /// found at the picture's cut and at the sound's.
    func audioHit(at point: CGPoint, option: Bool) -> AudioRowPointed? {
        guard let content, let geometry = geometry(), point.x >= TimelineLayout.headerWidth, point.y >= TimelineLayout.rulerHeight
        else { return nil }
        let y = point.y - TimelineLayout.rulerHeight + geometry.verticalOffset
        guard let row = geometry.rows.first(where: { y >= $0.top && y < $0.top + $0.height }), case let .audio(id) = row.track
        else { return nil }
        let x = point.x - TimelineLayout.headerWidth
        var ranges: [(id: String, x: ClosedRange<Double>, gain: Double)] = []
        if let mark = tracks.audioRows.mark, mark.track == id {
            ranges.append((TimelineAudioRows.markID, geometry.x(mark.output.lowerBound)...geometry.x(mark.output.upperBound), 0))
        }
        for range in content.audioRanges[id] ?? [] {
            ranges.append((range.id, geometry.x(range.output.lowerBound)...geometry.x(range.output.upperBound), range.gain))
        }
        let cuts = content.audioCuts.flatMap { [(clip: $0.clip, x: geometry.x($0.audio)), (clip: $0.clip, x: geometry.x($0.picture))] }
        let hit = AudioRowRules.hit(
            x: x, y: y - row.top - 2, option: option, height: row.height - 4, ranges: ranges, cuts: cuts,
            rowGain: AudioRowGeometry.decibels(ofTrackGain: content.audio[id]?.gain ?? 1))
        return AudioRowPointed(track: id, hit: hit, output: geometry.output(atX: x))
    }

    /// The cut of the sound moved off the picture's whose notch is within `AudioRowRules.grab` of `x` (the view's
    /// coordinates), the nearest: its clip.
    func movedCut(nearX x: Double) -> Int? {
        guard let content, let geometry = geometry() else { return nil }
        let area = x - TimelineLayout.headerWidth
        return content.audioCuts.filter { $0.audio != $0.picture && abs(geometry.x($0.audio) - area) <= AudioRowRules.grab }
            .min { abs(geometry.x($0.audio) - area) < abs(geometry.x($1.audio) - area) }?.clip
    }

    /// The capsule's place in the view's coordinates and what it is of, if it is shown.
    var audioCapsule: (frame: CGRect, track: String, range: String?)? {
        guard let spot = tracks.audioRows.capsuleSpot, let geometry = geometry() else { return nil }
        let frame = spot.frame.offsetBy(dx: TimelineLayout.headerWidth, dy: TimelineLayout.rulerHeight - geometry.verticalOffset)
        return (frame, spot.track, spot.range)
    }
}
