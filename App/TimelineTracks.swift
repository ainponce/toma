// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppKit
import AppSupport
import Editing
import ProjectFormat
import QuartzCore

/// The items of one track in output time, in the order of their start, and which of them are in sight: a binary search
/// and a walk over those, never the whole list.
struct TrackItems<Info> {
    struct Item {
        var id: String
        /// An empty range is an instant (a camera change).
        var output: Range<Int64>
        var info: Info
    }

    let items: [Item]
    /// The latest end of the items up to each one: the first that can reach a time is found by it.
    private let reach: [Int64]

    init(_ items: [Item]) {
        self.items = items.sorted { ($0.output.lowerBound, $0.output.upperBound) < ($1.output.lowerBound, $1.output.upperBound) }
        var latest = Int64.min
        reach = self.items.map { item in
            latest = max(latest, item.output.upperBound)
            return latest
        }
    }

    /// Calls `body` with each item that touches `lower...upper`, in order.
    func forEach(from lower: Int64, to upper: Int64, _ body: (Item) -> Void) {
        var (low, high) = (0, reach.count)
        while low < high {
            let middle = low + (high - low) / 2
            if reach[middle] < lower { low = middle + 1 } else { high = middle }
        }
        var i = low
        while i < items.count, items[i].output.lowerBound <= upper {
            if items[i].output.upperBound >= lower { body(items[i]) }
            i += 1
        }
    }
}

/// What the timeline shows of one revision of the document (design §5.5), in output time: what is cut is not there.
///
/// - Video: each clip of the sequence that lasts any output, with its speed.
/// - Screen: from 0 the screen the take starts on, and each change of screen from the first instant it rules
///   (`TimeMap.output(ofChangeAt:take:)`); a change whose stretch lasts nothing (in a cut, with another one after it in
///   the same cut) is not seen.
/// - Zoom: each block over the output its kept source is seen in (`TimeMap.outputRange(ofSource:take:)`: the cuts
///   inside it closed); a block all in a cut is not seen, and comes back if that part is brought back by a trim.
/// - Camera: each change at its own instant, if it is kept (`TimeMap.output(atSource:take:)`, as `EditPoints` reads it), and
///   each layout block where the preview shows it (`LayoutTimeline.blockOutputs`); a change inside a block is not seen while
///   it rules (`LayoutTimeline.hiddenChanges`).
/// - The ruler's markers: each `marker` event of the take at its instant, if it is kept: from the take's marker times,
///   found once per take (`markerTimes(in:)`), never by going over its events for each revision or drag move.
struct TimelineContent {
    struct ClipInfo {
        /// Its source's start, in host nanoseconds.
        var start: UInt64
        /// `ClipSpeed.clamped`.
        var speed: Double
        /// A clip with content (phase 3): a point of its take, of which nothing is heard, as the mix makes it silent
        /// (`EditedMix`), so its waveform is silence.
        var silent = false
    }

    struct Zoom {
        var depth: Double
        var automatic: Bool
    }

    struct Screen {
        var name: String
    }

    /// A layout block of the Camera track (design §5.5).
    struct LayoutBlockInfo {
        var kind: LayoutKind
        /// Where the camera is in a split; `nil` in any other layout.
        var side: CameraSide?
        var instant: Bool
    }

    /// A change of the camera's style.
    struct CameraChangeInfo {
        /// The layout of the block that hides it while it rules; `nil` outside the blocks.
        var hiddenBy: LayoutKind?
        var hidingBlock: String?
    }

    struct AudioTrack {
        var key: String
        var isMicrophone: Bool
        var gain: Double
        var muted: Bool
        /// The host time of pair 0 of its waveform: its earliest segment's start (`Waveform`).
        var origin: UInt64
        /// The same in each take that recorded the track, by take id (3d): each clip's waveform is its own take's.
        var origins: [String: UInt64] = [:]
    }

    let layout: TimelineLayout
    let map: TimeMap
    /// The document's sequence, which `map` maps.
    let sequence: [Clip]
    /// The clips that last any output.
    let clips: TrackItems<ClipInfo>
    let screens: TrackItems<Screen>
    let zooms: TrackItems<Zoom>
    let cameraChanges: TrackItems<CameraChangeInfo>
    /// The privacy blocks (phase 2 design §7.1).
    let privacy: TimelinePrivacyItems
    /// The annotations, in their lanes (phase 3 design §5.6).
    let annotations: TimelineAnnotationItems
    /// The clips with content of the Video track (phase 3 design §5.2–§5.4).
    let contentClips: TimelineContentClipItems
    /// The captions (phase 2 design §5.2); none without a transcript.
    let captions: TrackItems<CaptionInfo>
    /// The layout blocks, where the preview shows them.
    let layoutBlocks: TrackItems<LayoutBlockInfo>
    /// The ids of `layoutBlocks`, to tell a block from a camera change under the mouse.
    let layoutBlockIDs: Set<String>
    /// How a split sits in this project's format: the side its block label says.
    let splitOrientation: SplitOrientation
    /// The layout outside the blocks (the header's second line).
    let projectLayout: LayoutKind
    /// In order.
    let markers: [Int64]
    /// The spans of the screen or the camera that could not be read (`MissingVideo`), in order.
    let missing: [Range<Int64>]
    let audio: [String: AudioTrack]
    /// Where each clip's sound plays (phase 3 design §7.3: a J or L cut moves it off its picture), the stretches at another
    /// volume of each audio row by its track's id, where the output plays them (`AudioRangeCommands.shownRanges`), and
    /// the cuts of the sequence the sound can be cut at J or L (`AudioRowRules.cuts`).
    let audioWindows: TrackItems<AudioWindowInfo>
    let audioRanges: [String: [AudioRangeCommands.ShownRange]]
    let audioCuts: [(clip: Int, picture: Int64, audio: Int64)]
    /// The width of the screen the take starts on over its height: the thumbnails' shape.
    let screenAspect: Double
    /// The take the thumbnails of the frozen frames are of (`TimelineContentClipItems`): the session's own.
    let ownTake: String
    /// The screen shown from each source instant on: the take's first, then its changes in time order.
    private let initialScreen: String?
    private let screenChanges: [(t: UInt64, track: String)]
    /// The same for each take of `takes` and `take`, by take id (3d): what the thumbnails of each clip are of.
    private let screensOfTakes: [String: (initial: String?, changes: [(t: UInt64, track: String)])]

    /// The source instants of the take's `marker` events, in order: what the ruler's markers are made from. Goes over
    /// every event of the take; the editor does it once, off the main thread.
    static func markerTimes(in events: [InputEvent]) -> [HostTime] {
        events.compactMap { event -> HostTime? in
            if case .marker = event.kind { event.t } else { nil }
        }.sorted()
    }

    /// `markers`: the take's marker times (`markerTimes(in:)`); `contentRatio`: what "Like the Recording" follows; `takes`:
    /// those the sequence shows (`take` alone when empty), whose audio tracks have rows (`TimelineLayout(takes:document:)`).
    init(
        take: TakeRecord, markers: [HostTime], document: EditDocument, missing: [ClosedRange<Double>],
        contentRatio: Double? = nil, takes: [TakeRecord] = []
    ) {
        let map = TimeMap(sequence: document.sequence)
        let takeID = document.sequence.first?.take ?? take.id
        let takes = takes.isEmpty ? [take] : takes
        layout = TimelineLayout(takes: takes, document: document)
        self.map = map

        sequence = document.sequence
        clips = TrackItems(document.sequence.indices.compactMap { k in
            let clip = document.sequence[k], start = map.clipOutputStarts[k], length = TimeMap.outputDuration(of: clip)
            guard length > 0 else { return nil }
            return .init(
                id: clip.id, output: start..<(start + length),
                // A clip with content plays at no speed of its own: no badge, and silence under it.
                info: clip.content == nil
                    ? ClipInfo(start: clip.start.nanoseconds, speed: ClipSpeed.clamped(clip.speed))
                    : ClipInfo(start: clip.start.nanoseconds, speed: 1, silent: true))
        })

        let changes = document.screens.changes.filter { $0.take == takeID }.sorted { $0.t < $1.t }
        initialScreen = document.screens.initial[takeID]
        screenChanges = changes.map { ($0.t.nanoseconds, $0.track) }
        ownTake = take.id
        var screensOfTakes: [String: (initial: String?, changes: [(t: UInt64, track: String)])] = [:]
        for record in [take] + takes where screensOfTakes[record.id] == nil {
            screensOfTakes[record.id] = record.id == takeID
                ? (initialScreen, screenChanges)
                : (document.screens.initial[record.id],
                   document.screens.changes.filter { $0.take == record.id }.sorted { $0.t < $1.t }.map { ($0.t.nanoseconds, $0.track) })
        }
        self.screensOfTakes = screensOfTakes
        var spans: [(id: String, track: String?, start: Int64)] = [("initial", initialScreen, 0)]
        for change in changes {
            guard let rules = map.output(ofChangeAt: change.t, take: takeID) else { continue }
            spans.append((change.id, change.track, min(max(rules, 0), map.duration)))
        }
        var screenItems: [TrackItems<Screen>.Item] = []
        for (i, span) in spans.enumerated() {
            let end = i + 1 < spans.count ? spans[i + 1].start : map.duration
            guard let track = span.track, span.start < end else { continue }
            screenItems.append(.init(id: span.id, output: span.start..<end, info: Screen(name: take.track(track)?.source.name ?? track)))
        }
        screens = TrackItems(screenItems)

        zooms = TrackItems(document.zoom.regions.compactMap { region in
            guard region.start < region.end, let output = map.outputRange(ofSource: region.start..<region.end, take: region.take),
                !output.isEmpty
            else { return nil }
            return .init(
                id: region.id, output: output,
                info: Zoom(depth: region.depth ?? document.zoom.auto.depth, automatic: region.origin == .auto))
        })
        privacy = TimelinePrivacyItems(document: document)
        annotations = TimelineAnnotationItems(document: document, map: map)
        contentClips = TimelineContentClipItems(document: document, map: map, take: take.id)
        let output = StageLayout.outputSize(aspect: document.aspect, shortSide: 1080, contentRatio: contentRatio)
        captions = TimelineCaptionItems.items(document: document, map: map, outputSize: output)
        let orientation = CameraLayoutGeometry.orientation(output: SIMD2(Double(output.x), Double(output.y)))
        splitOrientation = orientation
        projectLayout = document.camera.layout.kind
        var blockItems: [TrackItems<LayoutBlockInfo>.Item] = []
        for (k, range) in LayoutTimeline.blockOutputs(of: document, timeMap: map).enumerated() {
            guard let range, !range.isEmpty else { continue }
            let block = document.camera.layouts[k]
            blockItems.append(.init(
                id: block.id, output: range,
                info: LayoutBlockInfo(
                    kind: block.kind, side: block.kind == .split ? block.split?.side ?? .end : nil, instant: block.instant)))
        }
        layoutBlocks = TrackItems(blockItems)
        layoutBlockIDs = Set(blockItems.map(\.id))
        let hidden = document.camera.layouts.isEmpty
            ? [:] : LayoutTimeline(document: document, take: take, timeMap: map, cameraReadable: true).hiddenChanges(document)
        let kinds = Dictionary(document.camera.layouts.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        cameraChanges = TrackItems(document.camera.changes.compactMap { change in
            map.output(atSource: change.t, take: change.take).map {
                let block = hidden[change.id]
                return .init(
                    id: change.id, output: $0..<$0, info: CameraChangeInfo(hiddenBy: block.flatMap { kinds[$0] }, hidingBlock: block))
            }
        })
        self.markers = markers.compactMap { map.output(atSource: $0, take: takeID) }.sorted()
        self.missing = missing.map { TimeMap.outputNanoseconds(seconds: $0.lowerBound)..<TimeMap.outputNanoseconds(seconds: $0.upperBound) }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }

        // Each audio row by its track's id: as `take` recorded it, or else the first of `takes` that did, with the gain the
        // mix reads for it (`AudioPlan.trackGain`).
        var audio: [String: AudioTrack] = [:]
        let takeIDs = takes.map(\.id)
        for record in [take] + takes {
            for track in record.tracks where !track.kind.isVideo {
                guard let origin = track.segments.map(\.startHostTime.nanoseconds).min() else { continue }
                guard audio[track.id] == nil else {
                    if audio[track.id]?.origins[record.id] == nil { audio[track.id]?.origins[record.id] = origin }
                    continue
                }
                let key = AudioPlan.key(take: record.id, track: track.id)
                let gain = document.audio.trackGain(take: record.id, track: track.id, takes: takeIDs)
                audio[track.id] = AudioTrack(
                    key: key, isMicrophone: track.kind == .microphone, gain: gain?.gain ?? 1, muted: gain?.muted ?? false,
                    origin: origin, origins: [record.id: origin])
            }
        }
        self.audio = audio
        audioWindows = TimelineAudioItems.windows(document.sequence, map: map)
        let hasRanges = document.audio.tracks.values.contains { !$0.ranges.isEmpty }
        audioRanges = hasRanges
            ? Dictionary(uniqueKeysWithValues: audio.keys.map { ($0, AudioRangeCommands.shownRanges(document, track: $0, timeMap: map)) }) : [:]
        audioCuts = AudioRowRules.cuts(document, timeMap: map)

        let first = initialScreen.flatMap(take.track)
        let frame = first?.source.captureArea ?? first?.source.globalFrame
        screenAspect = frame.map { $0.height > 0 ? min(max($0.width / $0.height, 0.5), 3) : 16.0 / 9 } ?? 16.0 / 9
    }

    /// The screen track shown at source instant `t` of the take: the last change at or before it, or the first screen.
    func screenTrack(atSource t: UInt64) -> String? {
        Self.screenTrack(atSource: t, initial: initialScreen, changes: screenChanges)
    }

    /// The same at source instant `t` of take `take` (3d), one of the takes the content was made with; `nil` for another.
    func screenTrack(atSource t: UInt64, take: String) -> String? {
        screensOfTakes[take].flatMap { Self.screenTrack(atSource: t, initial: $0.initial, changes: $0.changes) }
    }

    private static func screenTrack(atSource t: UInt64, initial: String?, changes: [(t: UInt64, track: String)]) -> String? {
        var (low, high) = (0, changes.count)
        while low < high {
            let middle = low + (high - low) / 2
            if changes[middle].t <= t { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? changes[low - 1].track : initial
    }
}

/// A waveform (`Waveform`, a minimum and a maximum every 10 ms) and its reductions by every power of two, so a column
/// of the timeline as wide as an hour reads a handful of values.
struct WaveformLevels: Sendable {
    /// `levels[n]`: each value covers 2ⁿ pairs.
    private let levels: [[SIMD2<Float>]]

    init(_ waveform: Waveform) {
        var levels = [waveform.pairs]
        while let last = levels.last, last.count > 1 {
            levels.append(stride(from: 0, to: last.count, by: 2).map { i in
                i + 1 < last.count ? SIMD2(min(last[i].x, last[i + 1].x), max(last[i].y, last[i + 1].y)) : last[i]
            })
        }
        self.levels = levels
    }

    /// The minimum and maximum of pairs `a ..< b` (fractions of a pair count as the pair), read from the level whose
    /// values are about as wide as that; `nil` if none of them is in the waveform.
    func range(fromPair a: Double, toPair b: Double) -> SIMD2<Float>? {
        guard let pairs = levels.first?.count, pairs > 0, b > 0, a < Double(pairs), b > a else { return nil }
        let count = max(b - a, 1)
        let level = min(max(Int(log2(count)), 0), levels.count - 1)
        let width = Double(1 << level)
        let values = levels[level]
        let first = max(Int(a / width), 0), last = min(Int((b - 1e-9) / width), values.count - 1)
        guard first <= last else { return nil }
        var low = Float.infinity, high = -Float.infinity
        for i in first...last {
            low = min(low, values[i].x)
            high = max(high, values[i].y)
        }
        return SIMD2(low, high)
    }
}

/// "2×", "1,5×", "0,25×": a speed or a zoom's depth, with the decimals it has (two at most) in the user's language.
@MainActor
enum TimelineFormat {
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    static func multiplier(_ value: Double) -> String {
        number(value) + "×"
    }

    /// `value` with the decimals it has (two at most) in the user's language: "1,5".
    static func number(_ value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

// MARK: - Drawing

/// A clip of the Video track: its outline (1 pt with Increase Contrast) and, if it is not at 1×, its speed.
final class ClipLayer: CALayer {
    let badge = CATextLayer()
    var badgeText: String?

    override init() {
        super.init()
        cornerRadius = 4
        badge.cornerRadius = 3
        badge.alignmentMode = .center
        TimelineText.setUp(badge, size: 10, weight: .semibold)
        addSublayer(badge)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// A zoom block: tinted with its hue, a border of it and a lighter top edge, its depth written on it; an automatic one
/// lighter, with the symbol of the automatic zoom (✦) before its depth.
final class BlockLayer: CAShapeLayer {
    let label = CATextLayer()
    let icon = CALayer()
    let highlight = CALayer()
    var labelText: String?
    var drawnSize = CGSize.zero
    var automatic: Bool?

    override init() {
        super.init()
        lineWidth = 1
        TimelineText.setUp(label, size: 10, weight: .semibold)
        icon.contentsGravity = .resizeAspect
        addSublayer(highlight)
        addSublayer(icon)
        addSublayer(label)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// A layout block of the Camera track: tinted like a zoom block, with the layout's symbol and its name; an instant one
/// has square corners where a smooth one has rounded ones (design §5.5).
final class LayoutBlockLayer: CAShapeLayer {
    let icon = CALayer()
    let label = CATextLayer()
    let highlight = CALayer()
    var labelText: String?
    var symbol: String?
    var drawnShape: (size: CGSize, instant: Bool)?

    override init() {
        super.init()
        TimelineText.setUp(label, size: 10, weight: .semibold)
        icon.contentsGravity = .resizeAspect
        addSublayer(highlight)
        addSublayer(icon)
        addSublayer(label)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// A stretch of the Screen track, with the screen's name.
final class SpanLayer: CALayer {
    let label = CATextLayer()
    let highlight = CALayer()
    var labelText: String?

    override init() {
        super.init()
        cornerRadius = 4
        TimelineText.setUp(label, size: 10, weight: .medium)
        addSublayer(highlight)
        addSublayer(label)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Draws the rows of the timeline under the ruler (design §5.5): Video, with thumbnails of the screen, its clips and the
/// hatching where the video could not be read; Screen; Zoom; Camera; and for each audio track its waveform over a region
/// per clip. The items are tinted with their track's hue, a border of it and a lighter top edge; selected, a stronger fill
/// and an outline in the accent color; all of it plain layers, without shadows or offscreen passes. One layer per
/// item in sight, taken from a pool and given back when it leaves it, so scrolling and scaling an hour with hundreds of
/// clips and blocks touches only what is in sight.
///
/// Thumbnails: each clip has its own grid of tiles (`TimelineLayout.thumbnailTiles`), from its start a power of two of
/// nanoseconds of output apart, each showing the frame of its clip at its left edge. While the scale changes within a
/// power of two the tiles keep their frames and slide with the clip (across one, half of them do), and an edit that moves
/// a clip moves its tiles with the same frames. They come from the `ThumbnailCache`, which makes them off the main
/// thread; the last 400 are kept here, and a tile that leaves the sight before its thumbnail is made cancels it.
@MainActor
final class TimelineTracks {
    /// The rows, scrolled up and down; its frame is the tracks' area under the ruler.
    let layer = CALayer()
    private let rows = CALayer()
    private let separators = CAShapeLayer()
    private let thumbnailStrip = CALayer()
    private let clipMask = CAShapeLayer()
    private let clipLayers: LayerPool<ClipLayer>
    private let tiles: LayerPool<CALayer>
    private let hatches: LayerPool<CAShapeLayer>
    private let blocks: LayerPool<BlockLayer>
    private let spans: LayerPool<SpanLayer>
    private let layouts: LayerPool<LayoutBlockLayer>
    private let diamonds: LayerPool<CALayer>
    private let cameraNotice = CATextLayer()
    /// The audio rows: their waveforms, volume lines, stretches and cuts of the sound (phase 3).
    let audioRows = TimelineAudioRows()
    /// The Privacy row's blocks (phase 2).
    private let privacyRow = TimelinePrivacyRow()
    /// The Annotations row's blocks (phase 3).
    private let annotationsRow = TimelineAnnotationsRow()
    /// The clips with content of the Video row (phase 3), and the lengths and frames of the imported clips' files.
    let contentClips = TimelineContentClipsRow()
    /// The Captions row's blocks (phase 2).
    private let captionsRow = CaptionTrackLayers()
    /// The output time under the playhead, for the caption it highlights (`moved(playhead:)` when it moves).
    private(set) var playhead: Int64 = 0

    /// The thumbnails of each take by take id, and the waveforms worked out so far by take and audio track
    /// (`AudioPlan.key(take:track:)`): each clip's are its own take's (3d).
    var thumbnailCaches: [String: ThumbnailCache] = [:]
    var waveformLevels: [String: WaveformLevels] = [:]
    /// Called once a thumbnail arrived, to draw it.
    var thumbnailArrived: () -> Void = {}
    /// The items that are selected (outlined in the accent color), by id.
    var selected: Set<String> = []
    /// The camera cannot be read: the row says so, and the layouts that need it show only the screen.
    var cameraUnreadable = false
    /// This update moves the items to their new places with `Motion.trackItem` (after an edit), not at once.
    var settling = false

    private struct ThumbnailKey: Hashable {
        var take: String
        var track: String
        var source: UInt64
        var height: Int
    }
    /// What was made, `nil` when there is none (the source is in no segment that can be read), oldest first.
    private var thumbnails: [ThumbnailKey: CGImage?] = [:]
    private var thumbnailOrder: [ThumbnailKey] = []
    private var loading: [ThumbnailKey: Task<Void, Never>] = [:]
    /// The thumbnail each tile shows, or is waiting for.
    private var tileKeys: [String: ThumbnailKey] = [:]
    private static let keptThumbnails = 400
    /// The narrowest piece of a thumbnail drawn: under it, the clip's color.
    private static let narrowestThumbnail = 16.0

    init() {
        layer.masksToBounds = true
        layer.addSublayer(rows)
        thumbnailStrip.mask = clipMask
        rows.addSublayer(thumbnailStrip)
        thumbnailStrip.addSublayer(contentClips.layer)
        clipLayers = LayerPool(parent: rows) { ClipLayer() }
        hatches = LayerPool(parent: rows) {
            let hatch = CAShapeLayer()
            hatch.lineWidth = 1
            hatch.masksToBounds = true
            return hatch
        }
        tiles = LayerPool(parent: thumbnailStrip) {
            // At its own size (it is made as tall as the tile), from the tile's left; a tile's last piece cuts it.
            let tile = CALayer()
            tile.contentsGravity = .left
            tile.masksToBounds = true
            return tile
        }
        spans = LayerPool(parent: rows) { SpanLayer() }
        blocks = LayerPool(parent: rows) { BlockLayer() }
        layouts = LayerPool(parent: rows) {
            let block = LayoutBlockLayer()
            block.lineWidth = 1
            block.zPosition = 1
            return block
        }
        diamonds = LayerPool(parent: rows) {
            let diamond = CALayer()
            diamond.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 4))
            diamond.zPosition = 2
            return diamond
        }
        rows.addSublayer(audioRows.layer)
        TimelineText.setUp(cameraNotice, size: 10, weight: .regular)
        cameraNotice.string = String(localized: "The camera can't be read: only the screen is shown.")
        rows.addSublayer(cameraNotice)
        rows.addSublayer(privacyRow.layer)
        rows.addSublayer(annotationsRow.layer)
        rows.addSublayer(captionsRow.layer)
        contentClips.arrived = { [weak self] in self?.thumbnailArrived() }
        layer.addSublayer(separators)
        separators.lineWidth = 1
        separators.fillColor = nil
    }

    /// Lays out what is in sight of `content` at `geometry`; called inside a transaction without actions.
    func update(_ content: TimelineContent, _ geometry: TimelineGeometry, _ palette: TimelinePalette) {
        layer.isHidden = false
        rows.frame = CGRect(x: 0, y: -geometry.verticalOffset, width: geometry.areaWidth, height: geometry.rowsHeight)
        separators.frame = layer.bounds
        separators.strokeColor = palette.separator
        let lines = CGMutablePath()
        for row in geometry.rows {
            let y = (row.top + row.height - geometry.verticalOffset).rounded() - 0.5
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: geometry.areaWidth, y: y))
        }
        separators.path = lines

        for pool in [clipLayers.begin, tiles.begin, hatches.begin, blocks.begin, spans.begin, layouts.begin, diamonds.begin] {
            pool()
        }
        privacyRow.begin()
        annotationsRow.begin()
        contentClips.begin()
        captionsRow.begin()
        audioRows.begin()
        var wanted: Set<ThumbnailKey> = []
        for row in geometry.rows {
            switch row.track {
            case .ruler: break
            case .video: layOutVideo(content, row, geometry, palette, &wanted)
            case .screen: layOutScreens(content, row, geometry, palette)
            case .zoom: layOutZooms(content, row, geometry, palette)
            case .captions: captionsRow.layOut(content, row, geometry, palette, playhead: playhead)
            case .privacy: privacyRow.layOut(content, row, geometry, palette, selected: selected, settling: settling)
            case .camera: layOutCamera(content, row, geometry, palette)
            case let .audio(id):
                let levels = waveformLevels
                audioRows.layOut(
                    id, content, row, geometry, palette, levels: { levels[AudioPlan.key(take: $0, track: id)] }, selected: selected,
                    settling: settling)
            case .annotations: annotationsRow.layOut(content, row, geometry, palette, selected: selected, settling: settling)
            // Empty in the base of phase 3: the sound (3c) draws in them.
            case .importedAudio, .music: break
            }
        }
        for pool in [clipLayers.end, tiles.end, hatches.end, blocks.end, spans.end, layouts.end, diamonds.end] { pool() }
        privacyRow.end()
        annotationsRow.end()
        contentClips.end()
        captionsRow.end()
        audioRows.end()
        // What is no longer in sight is not made.
        for (key, task) in loading where !wanted.contains(key) {
            task.cancel()
            loading[key] = nil
        }
    }

    /// The playhead moved to output time `τ`: the caption under it is highlighted.
    func moved(playhead τ: Int64) {
        playhead = τ
        captionsRow.highlight(playhead: τ)
    }

    /// Nothing to show (the project is opening, or cannot be shown).
    func clear() {
        layer.isHidden = true
        for task in loading.values { task.cancel() }
        loading = [:]
        contentClips.stop()
    }

    /// Forgets the layers, so the next update makes them again with new colors.
    func reset() {
        for pool in [
            clipLayers.removeAll, tiles.removeAll, hatches.removeAll, blocks.removeAll, spans.removeAll, layouts.removeAll,
            diamonds.removeAll,
        ] {
            pool()
        }
        privacyRow.reset()
        annotationsRow.reset()
        contentClips.reset()
        captionsRow.reset()
        audioRows.reset()
        tileKeys = [:]
    }

    /// Forgets the thumbnails (another project, or the package moved).
    func forgetThumbnails() {
        for task in loading.values { task.cancel() }
        loading = [:]
        thumbnails = [:]
        thumbnailOrder = []
        tileKeys = [:]
        tiles.removeAll()
        contentClips.forgetFrames()
    }

    /// How many layers the rows have in sight now, for the benchmark.
    var layerCount: Int {
        clipLayers.shownCount + tiles.shownCount + hatches.shownCount + blocks.shownCount + spans.shownCount
            + layouts.shownCount + diamonds.shownCount + audioRows.layerCount + captionsRow.layerCount
            + contentClips.layerCount
    }

    // MARK: - Video

    private func layOutVideo(
        _ content: TimelineContent, _ row: TimelineGeometry.Row, _ geometry: TimelineGeometry, _ palette: TimelinePalette,
        _ wanted: inout Set<ThumbnailKey>
    ) {
        let top = row.top + 2, height = row.height - 4
        thumbnailStrip.frame = CGRect(x: 0, y: top, width: geometry.areaWidth, height: height)
        thumbnailStrip.backgroundColor = palette.clipFill
        clipMask.frame = thumbnailStrip.bounds
        let mask = CGMutablePath()
        let (lower, upper) = geometry.visibleOutput
        content.clips.forEach(from: lower, to: upper) { item in
            guard let rect = geometry.itemRect(item.output, top: top, height: height, gap: 1) else { return }
            let radius = min(4, rect.width / 2)
            mask.addRoundedRect(in: CGRect(x: rect.minX, y: 0, width: rect.width, height: height), cornerWidth: radius, cornerHeight: radius)
            let (clip, isNew) = clipLayers.layer(item.id)
            if isNew {
                clip.badge.backgroundColor = palette.badgeFill
                clip.badge.foregroundColor = palette.badgeText
                clip.borderColor = palette.contrastBorder
                clip.badge.contentsScale = geometry.backingScale
            }
            place(clip, rect, isNew: isNew)
            let isSelected = selected.contains(item.id)
            clip.borderColor = isSelected ? palette.selection : (palette.increaseContrast ? palette.contrastBorder : palette.clipEdge)
            clip.borderWidth = isSelected ? 2 : 1
            let text = item.info.speed == 1 ? nil : TimelineFormat.multiplier(item.info.speed)
            if clip.badgeText != text {
                clip.badgeText = text
                clip.badge.string = text
            }
            let badgeWidth = CGFloat((text?.count ?? 0) * 6 + 8)
            clip.badge.isHidden = text == nil || rect.width < badgeWidth + 6
            clip.badge.frame = CGRect(x: max(3, -rect.minX + 3), y: 3, width: badgeWidth, height: 14)
        }
        let previousMask = clipMask.path
        clipMask.path = mask
        if settling, let previousMask, previousMask != mask, Self.sameShape(previousMask, mask) {
            let morph = CASpringAnimation(keyPath: "path", spring: Motion.trackItem)
            morph.fromValue = previousMask
            morph.toValue = mask
            clipMask.add(morph, forKey: "settle")
        }

        layOutThumbnails(content, geometry, height: height, &wanted)
        // A frozen frame, a title card and an imported clip (phase 3), over the strip.
        contentClips.layOut(
            content, geometry, palette, height: height, selected: selected, settling: settling,
            thumbnails: thumbnailCaches[content.ownTake])

        for (i, span) in content.missing.enumerated() where span.upperBound >= lower && span.lowerBound <= upper {
            guard let rect = geometry.itemRect(span, top: top, height: height, gap: 0) else { continue }
            let (hatch, isNew) = hatches.layer("\(i)")
            if isNew {
                hatch.strokeColor = palette.hatchStroke
                hatch.backgroundColor = palette.hatchFill
                hatch.fillColor = nil
            }
            // Stripes every 6 pt from the span's start, so they move with it when only a part of it is in sight.
            let stripes = CGMutablePath()
            let phase = (geometry.x(span.lowerBound) - rect.minX).truncatingRemainder(dividingBy: 6)
            var x = phase - (rect.height / 6).rounded(.up) * 6
            while x < rect.width {
                stripes.move(to: CGPoint(x: x, y: rect.height))
                stripes.addLine(to: CGPoint(x: x + rect.height, y: 0))
                x += 6
            }
            hatch.path = stripes
            hatch.frame = rect
        }
    }

    /// The thumbnail tiles in sight, each showing the frame at its left edge from its left, cut at its clip's end, of its
    /// clip's own take (3d), or the clip's color until it arrives (never a frame of another time).
    private func layOutThumbnails(
        _ content: TimelineContent, _ geometry: TimelineGeometry, height: Double, _ wanted: inout Set<ThumbnailKey>
    ) {
        guard !thumbnailCaches.isEmpty, height > 0 else { return }
        let pixels = min(max(Int((height * geometry.backingScale).rounded()), 1), 512)
        let (lower, upper) = geometry.visibleOutput
        let inSight = TimelineLayout.thumbnailTiles(
            sequence: content.sequence, map: content.map, visible: lower..<max(upper, lower), scale: geometry.scale,
            tileWidth: (height * content.screenAspect).rounded(), minimumWidth: Self.narrowestThumbnail)
        for tile in inSight {
            let take = content.sequence[tile.clip].take
            guard let cache = thumbnailCaches[take], let track = content.screenTrack(atSource: tile.source.nanoseconds, take: take)
            else { continue }
            let key = ThumbnailKey(take: take, track: track, source: tile.source.nanoseconds, height: pixels)
            wanted.insert(key)
            let id = "\(content.sequence[tile.clip].id) \(tile.index)"
            let (layer, isNew) = tiles.layer(id)
            if isNew { layer.contentsScale = geometry.backingScale }
            let minX = geometry.snapped(geometry.x(tile.output)), maxX = geometry.snapped(geometry.x(tile.end))
            layer.frame = CGRect(x: minX, y: 0, width: maxX - minX, height: height)
            if isNew || tileKeys[id] != key {
                tileKeys[id] = key
                layer.contents = nil
            }
            if let made = thumbnails[key] {
                if layer.contents == nil, let made { layer.contents = made }
            } else {
                request(key, from: cache)
            }
        }
    }

    private func request(_ key: ThumbnailKey, from cache: ThumbnailCache) {
        guard loading[key] == nil else { return }
        loading[key] = Task { [weak self] in
            let image = await cache.thumbnail(track: key.track, source: HostTime(nanoseconds: key.source), height: key.height)
            guard !Task.isCancelled, let self else { return }
            self.loading[key] = nil
            self.keep(key, image)
            self.thumbnailArrived()
        }
    }

    private func keep(_ key: ThumbnailKey, _ image: CGImage?) {
        if thumbnails.updateValue(image, forKey: key) == nil { thumbnailOrder.append(key) }
        if thumbnailOrder.count > Self.keptThumbnails {
            let dropped = thumbnailOrder.removeFirst()
            thumbnails[dropped] = nil
        }
    }

    // MARK: - Settling

    /// Puts `layer` at `rect`; settling, it goes there from where it was with `Motion.trackItem`.
    private func place(_ layer: CALayer, _ rect: CGRect, isNew: Bool) {
        let from = layer.presentation()?.frame ?? layer.frame
        layer.frame = rect
        guard settling, !isNew, from != rect else { return }
        let move = CASpringAnimation(keyPath: "position", spring: Motion.trackItem)
        move.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
        move.toValue = NSValue(point: CGPoint(x: rect.midX, y: rect.midY))
        let grow = CASpringAnimation(keyPath: "bounds", spring: Motion.trackItem)
        grow.fromValue = NSValue(rect: CGRect(origin: .zero, size: from.size))
        grow.toValue = NSValue(rect: CGRect(origin: .zero, size: rect.size))
        layer.add(move, forKey: "settleMove")
        layer.add(grow, forKey: "settleSize")
    }

    /// Whether two paths have the same elements, so one can morph into the other.
    private static func sameShape(_ a: CGPath, _ b: CGPath) -> Bool {
        func kinds(_ path: CGPath) -> [CGPathElementType] {
            var kinds: [CGPathElementType] = []
            path.applyWithBlock { kinds.append($0.pointee.type) }
            return kinds
        }
        return kinds(a) == kinds(b)
    }

    // MARK: - Screen, Zoom, Camera

    private func layOutScreens(
        _ content: TimelineContent, _ row: TimelineGeometry.Row, _ geometry: TimelineGeometry, _ palette: TimelinePalette
    ) {
        let top = row.top + 2, height = row.height - 4
        let (lower, upper) = geometry.visibleOutput
        content.screens.forEach(from: lower, to: upper) { item in
            guard let rect = geometry.itemRect(item.output, top: top, height: height, gap: 1) else { return }
            let (span, isNew) = spans.layer(item.id)
            if isNew {
                span.label.foregroundColor = palette.screen.text
                span.label.contentsScale = geometry.backingScale
                span.highlight.backgroundColor = palette.highlight
            }
            place(span, rect, isNew: isNew)
            let isSelected = selected.contains(item.id)
            span.backgroundColor = isSelected ? palette.screen.selectedFill : palette.screen.fill
            span.borderColor = isSelected ? palette.selection : (palette.increaseContrast ? palette.contrastBorder : palette.screen.stroke)
            span.borderWidth = isSelected ? 2 : 1
            Self.placeHighlight(span.highlight, width: rect.width, radius: 4, geometry)
            if span.labelText != item.info.name {
                span.labelText = item.info.name
                span.label.string = item.info.name
            }
            // The name stays at the left of what is in sight.
            let left = max(6, -rect.minX + 6)
            span.label.frame = CGRect(x: left, y: (height - 13) / 2, width: max(rect.width - left - 4, 0), height: 13)
            span.label.isHidden = rect.width < 24
        }
    }

    private func layOutZooms(
        _ content: TimelineContent, _ row: TimelineGeometry.Row, _ geometry: TimelineGeometry, _ palette: TimelinePalette
    ) {
        let top = row.top + 3, height = row.height - 6
        let (lower, upper) = geometry.visibleOutput
        content.zooms.forEach(from: lower, to: upper) { item in
            guard let rect = geometry.itemRect(item.output, top: top, height: height, gap: 1) else { return }
            let (block, isNew) = blocks.layer(item.id)
            if isNew {
                block.label.contentsScale = geometry.backingScale
                block.icon.contentsScale = geometry.backingScale
                block.highlight.backgroundColor = palette.highlight
            }
            let automatic = item.info.automatic
            let tint = automatic ? palette.zoomAuto : palette.zoom
            if block.automatic != automatic || isNew {
                block.automatic = automatic
                block.label.foregroundColor = tint.text
                block.icon.contents = automatic ? Self.symbolImage("sparkles", scale: geometry.backingScale, color: tint.text) : nil
            }
            let isSelected = selected.contains(item.id)
            block.fillColor = isSelected ? tint.selectedFill : tint.fill
            block.strokeColor = isSelected ? palette.selection : (palette.increaseContrast ? palette.contrastBorder : tint.stroke)
            block.lineWidth = isSelected ? 2 : 1
            let previousPath = block.path
            place(block, rect, isNew: isNew)
            if block.drawnSize != rect.size {
                block.drawnSize = rect.size
                let radius = min(5, rect.width / 2, rect.height / 2)
                block.path = CGPath(
                    roundedRect: CGRect(origin: .zero, size: rect.size).insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(radius - 0.5, 0),
                    cornerHeight: max(radius - 0.5, 0), transform: nil)
                if settling, !isNew, let previousPath, let path = block.path {
                    let morph = CASpringAnimation(keyPath: "path", spring: Motion.trackItem)
                    morph.fromValue = previousPath
                    morph.toValue = path
                    block.add(morph, forKey: "settleShape")
                }
            }
            let text = TimelineFormat.multiplier(item.info.depth)
            if block.labelText != text {
                block.labelText = text
                block.label.string = text
            }
            // The depth (and an automatic block's symbol) stays at the left of what is in sight.
            let left = max(6, -rect.minX + 6)
            let icon = automatic && rect.width >= 36
            block.icon.isHidden = !icon
            block.icon.frame = CGRect(x: left, y: (height - 10) / 2, width: 10, height: 10)
            let textLeft = icon ? left + 13 : left
            block.label.frame = CGRect(x: textLeft, y: (height - 13) / 2, width: max(rect.width - textLeft - 3, 0), height: 13)
            block.label.isHidden = rect.width < 22
            Self.placeHighlight(block.highlight, width: rect.width, radius: min(5, rect.width / 2, rect.height / 2), geometry)
        }
    }

    private func layOutCamera(
        _ content: TimelineContent, _ row: TimelineGeometry.Row, _ geometry: TimelineGeometry, _ palette: TimelinePalette
    ) {
        layOutCameraNotice(row, geometry, palette)
        layOutLayoutBlocks(content, row, geometry, palette)
        let side = 9.0
        // An instant is in sight while its diamond is.
        let margin = Int64(side / geometry.scale * 1e9)
        let (lower, upper) = geometry.visibleOutput
        content.cameraChanges.forEach(from: lower - margin, to: upper + margin) { item in
            let (diamond, isNew) = diamonds.layer(item.id)
            if isNew {
                diamond.backgroundColor = palette.camera
                diamond.borderColor = palette.contrastBorder
            }
            let isSelected = selected.contains(item.id)
            // A ring of the timeline's background keeps it apart from a block under it.
            diamond.borderColor = isSelected ? palette.selection : (palette.increaseContrast ? palette.contrastBorder : palette.background)
            diamond.borderWidth = isSelected ? 2 : 1
            // Inside a block it is not seen while the block rules: dimmed, and its help says so (the view's tooltip).
            diamond.opacity = item.info.hiddenBy == nil ? 1 : Float(LayoutTrackRules.dimmedDiamondOpacity)
            diamond.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            let previous = diamond.position
            let position = CGPoint(x: geometry.snapped(geometry.x(item.output.lowerBound)), y: row.top + row.height / 2)
            diamond.position = position
            if settling, !isNew, previous != position {
                let move = CASpringAnimation(keyPath: "position", spring: Motion.trackItem)
                move.fromValue = NSValue(point: previous)
                move.toValue = NSValue(point: position)
                diamond.add(move, forKey: "settle")
            }
        }
    }

    /// "The camera can't be read: only the screen is shown." at the row's left, under the blocks.
    private func layOutCameraNotice(_ row: TimelineGeometry.Row, _ geometry: TimelineGeometry, _ palette: TimelinePalette) {
        cameraNotice.isHidden = !cameraUnreadable
        guard cameraUnreadable else { return }
        cameraNotice.contentsScale = geometry.backingScale
        cameraNotice.foregroundColor = palette.label
        cameraNotice.frame = CGRect(x: 8, y: row.top + (row.height - 13) / 2, width: max(geometry.areaWidth - 16, 0), height: 13)
    }

    /// The layout blocks: the symbol and the name of the layout (with a split, where the camera is), filled; selected, with
    /// an outline in the accent color; an instant one with square corners.
    private func layOutLayoutBlocks(
        _ content: TimelineContent, _ row: TimelineGeometry.Row, _ geometry: TimelineGeometry, _ palette: TimelinePalette
    ) {
        let top = row.top + 3, height = row.height - 6
        let (lower, upper) = geometry.visibleOutput
        content.layoutBlocks.forEach(from: lower, to: upper) { item in
            guard let rect = geometry.itemRect(item.output, top: top, height: height, gap: 1) else { return }
            let (block, isNew) = layouts.layer(item.id)
            if isNew {
                block.label.contentsScale = geometry.backingScale
                block.icon.contentsScale = geometry.backingScale
                block.label.foregroundColor = palette.layout.text
                block.highlight.backgroundColor = palette.highlight
                block.symbol = nil
            }
            let isSelected = selected.contains(item.id)
            block.fillColor = isSelected ? palette.layout.selectedFill : palette.layout.fill
            block.strokeColor = isSelected ? palette.selection : (palette.increaseContrast ? palette.contrastBorder : palette.layout.stroke)
            block.lineWidth = isSelected ? 2 : 1
            let previousPath = block.path
            place(block, rect, isNew: isNew)
            let shape = (size: rect.size, instant: item.info.instant)
            if block.drawnShape?.size != shape.size || block.drawnShape?.instant != shape.instant {
                block.drawnShape = shape
                let radius = item.info.instant ? 0 : min(5, rect.width / 2, rect.height / 2)
                block.path = CGPath(
                    roundedRect: CGRect(origin: .zero, size: rect.size).insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(radius - 0.5, 0),
                    cornerHeight: max(radius - 0.5, 0), transform: nil)
                if settling, !isNew, let previousPath, let path = block.path, Self.sameShape(previousPath, path) {
                    let morph = CASpringAnimation(keyPath: "path", spring: Motion.trackItem)
                    morph.fromValue = previousPath
                    morph.toValue = path
                    block.add(morph, forKey: "settleShape")
                }
            }
            let symbol = LayoutTrackRules.symbol(item.info.kind, orientation: content.splitOrientation)
            if block.symbol != symbol {
                block.symbol = symbol
                block.icon.contents = Self.symbolImage(symbol, scale: geometry.backingScale, color: palette.layout.text)
            }
            let text = Self.title(item.info, orientation: content.splitOrientation)
            if block.labelText != text {
                block.labelText = text
                block.label.string = text
            }
            let left = max(5, -rect.minX + 5)
            block.icon.frame = CGRect(x: left, y: (height - 12) / 2, width: 12, height: 12)
            block.icon.isHidden = rect.width < 22
            block.label.frame = CGRect(x: left + 16, y: (height - 13) / 2, width: max(rect.width - left - 19, 0), height: 13)
            block.label.isHidden = rect.width < 60
            Self.placeHighlight(
                block.highlight, width: rect.width, radius: item.info.instant ? 0 : min(5, rect.width / 2, rect.height / 2), geometry)
        }
    }

    /// The lighter top edge of a tinted item `width` wide with corners of `radius`: a line of a pixel, inside its border
    /// and between its corners.
    private static func placeHighlight(_ highlight: CALayer, width: Double, radius: Double, _ geometry: TimelineGeometry) {
        let inset = max(radius, 1)
        highlight.isHidden = width < 2 * inset + 2
        highlight.frame = CGRect(x: inset, y: 1, width: max(width - 2 * inset, 0), height: 1 / geometry.backingScale)
    }

    /// The name of a block's layout, with the side of the camera in a split (design §5.5).
    static func title(_ info: TimelineContent.LayoutBlockInfo, orientation: SplitOrientation) -> String {
        guard info.kind == .split, let side = info.side else { return LayoutNames.name(info.kind) }
        switch LayoutTrackRules.labelSide(side, orientation: orientation) {
        case .left: return String(localized: "Split · camera on the left")
        case .right: return String(localized: "Split · camera on the right")
        case .top: return String(localized: "Split · camera on top")
        case .bottom: return String(localized: "Split · camera at the bottom")
        }
    }

    private static var symbols: [String: CGImage] = [:]

    /// The symbol in `color`, at the block's text size, for a display of `scale` pixels per point.
    private static func symbolImage(_ name: String, scale: Double, color: CGColor) -> CGImage? {
        let key = "\(name)@\(scale) \(color.components ?? [])"
        if let image = symbols[key] { return image }
        let tint = NSColor(cgColor: color) ?? .white
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        let drawn = image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scaleByX: scale, byY: scale)])
        if let drawn { symbols[key] = drawn }
        return drawn
    }
}
