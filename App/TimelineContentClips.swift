// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import AppSupport
import Editing
import ProjectFormat
import QuartzCore

/// The clips with content of the Video track of one revision of the document (phase 3 design §5.2–§5.4, plan 3a Task
/// A15), by id: a frozen frame shows its frame, still, with a snowflake; a title card is tinted, with its title; an
/// imported clip shows its file's frames, with a strip of film.
struct TimelineContentClipItems {
    enum Kind: Equatable {
        /// The take's frame at the clip's point; `thumbnailed` when it is of the take the thumbnails are made of.
        case freeze(point: HostTime, thumbnailed: Bool)
        /// What the block says: the card's title on one line (`ContentClipTrackRules.label`), `nil` without one.
        case card(title: String?)
        case media(asset: String)
    }

    struct Info {
        var kind: Kind
        /// The clip as the document has it, where it starts in the output and what it lasts there.
        var clip: Clip
        var outputStart: Int64
        var duration: Int64
    }

    private let byID: [String: Info]

    /// `take`: the take whose screen the thumbnails are made of (`ThumbnailCache`).
    init(document: EditDocument, map: TimeMap, take: String) {
        var byID: [String: Info] = [:]
        for (k, clip) in document.sequence.enumerated() {
            guard let content = clip.content, k < map.clipOutputStarts.count else { continue }
            let duration = TimeMap.outputDuration(of: clip)
            guard duration > 0 else { continue }
            let kind: Kind
            switch content {
            case .freeze: kind = .freeze(point: clip.start, thumbnailed: clip.take == take)
            case .card: kind = .card(title: ContentClipTrackRules.label(of: clip))
            case let .media(media): kind = .media(asset: media.asset)
            }
            byID[clip.id] = Info(kind: kind, clip: clip, outputStart: map.clipOutputStarts[k], duration: duration)
        }
        self.byID = byID
    }

    /// Clip `id`, if it is a clip with content the output shows.
    func info(_ id: String) -> Info? {
        byID[id]
    }

    var isEmpty: Bool { byID.isEmpty }

    /// The symbol of each (plan 3a decision 20): a snowflake, a text box, a strip of film.
    static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .freeze: "snowflake"
        case .card: "character.textbox"
        case .media: "film"
        }
    }

    /// What VoiceOver reads of it: "Placa «Intro», 3 s", "Cuadro congelado, 2 s", "Clip importado, 4,5 s".
    @MainActor
    static func accessibilityLabel(_ info: Info) -> String {
        let length = seconds(info.duration)
        switch info.kind {
        case .freeze:
            return String(format: String(localized: "Frozen Frame, %@", comment: "VoiceOver: a frozen frame of the Video track and what it lasts (\"2 s\")"), length)
        case let .card(title?):
            return String(format: String(localized: "Title Card “%@”, %@", comment: "VoiceOver: a title card of the Video track, its title and what it lasts (\"3 s\")"), title, length)
        case .card(nil):
            return String(format: String(localized: "Title Card, %@", comment: "VoiceOver: a title card without a title on the Video track and what it lasts (\"3 s\")"), length)
        case .media:
            return String(format: String(localized: "Imported Clip, %@", comment: "VoiceOver: an imported video in the sequence on the Video track and what it lasts (\"4,5 s\")"), length)
        }
    }

    /// "3 s", "2,7 s": a length of output to the tenth of a second, in the user's language.
    @MainActor
    static func seconds(_ τ: Int64) -> String {
        TimelineFormat.number((Double(τ) / 1e8).rounded() / 10) + " s"
    }

    /// The label of a drag of an edge of the imported clip `clip` (which starts at output `outputStart`) as `preview` has
    /// it: how far the edge moved in the output and where it is now; it has not moved without the clip in `preview`.
    static func trimLabel(_ clip: Clip, edge: ClipEdge, outputStart: Int64, in preview: EditDocument?) -> (delta: Int64, position: Int64) {
        let edgeOutput = outputStart + (edge == .start ? 0 : TimeMap.outputDuration(of: clip))
        guard case let .media(before)? = clip.content,
            case let .media(after)? = preview?.sequence.first(where: { $0.id == clip.id })?.content
        else { return (0, edgeOutput) }
        let moved = edge == .start ? after.start &- before.start : after.end &- before.end
        let delta = Int64((Double(moved) / ClipSpeed.clamped(before.speed)).rounded())
        return (delta, edgeOutput + delta)
    }
}

// MARK: - The imported clips' files

/// The lengths and the frames of a package's imported clips, for the Video track: read where
/// `ProjectPackage.mediaAsset(_:as:)` says each is (never through a link), off the main thread. A clip's `MediaInfo`
/// once (`MediaInfo.probe`), its frames with `AVAssetImageGenerator`, which decodes on AVFoundation's own threads and
/// answers through a callback, a frame up to half a second before the time asked for (never a later one), as the take's
/// thumbnails are (`ThumbnailCache`). It keeps the generators of the last four clips it read.
actor MediaClipFrames {
    private let package: ProjectPackage
    private var infos: [String: MediaInfo?] = [:]
    private var generators: [(asset: String, generator: AVAssetImageGenerator)] = []
    private static let keptGenerators = 4

    init(package: ProjectPackage) {
        self.package = package
    }

    /// What `asset` is (its length, its picture's size), read once; `nil` if it cannot be read.
    func info(_ asset: String) async -> MediaInfo? {
        if let known = infos[asset] { return known }
        let probed = await MediaInfo.probe(asset, in: package)
        // A probe cancelled half way says nothing about the file.
        if !Task.isCancelled { infos[asset] = .some(probed) }
        return probed
    }

    /// The frame of `asset` at `time` ns of the file, `height` pixels high (as wide as it is, up to eight times that);
    /// `nil` if it cannot be read or for a caller cancelled first.
    func frame(_ asset: String, at time: UInt64, height: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let current: AVAssetImageGenerator
        if let kept = generators.firstIndex(where: { $0.asset == asset }) {
            current = generators[kept].generator
        } else {
            guard let url = package.mediaAsset(asset, as: .video) else { return nil }
            current = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            current.appliesPreferredTrackTransform = true
            current.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
            current.requestedTimeToleranceAfter = .zero
            generators.append((asset, current))
            if generators.count > Self.keptGenerators { generators.removeFirst() }
        }
        current.maximumSize = CGSize(width: height * 8, height: height)
        let at = CMTime(value: CMTimeValue(clamping: time), timescale: 1_000_000_000)
        return await withCheckedContinuation { continuation in
            current.generateCGImageAsynchronously(for: at) { image, _, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

// MARK: - Drawing

/// A clip with content's decoration over its thumbnails: a title card's tint and title; the symbol of each, on a dark
/// badge over a frame.
final class ContentClipLayer: CALayer {
    let badge = CALayer()
    let icon = CALayer()
    let label = CATextLayer()
    var symbol: String?
    var symbolColor: CGColor?
    var labelText: String?

    override init() {
        super.init()
        badge.cornerRadius = 3
        icon.contentsGravity = .resizeAspect
        TimelineText.setUp(label, size: 10, weight: .semibold)
        addSublayer(badge)
        badge.addSublayer(icon)
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

/// Draws the clips with content of the Video track (`TimelineTracks` calls it inside its update, without actions), in
/// the thumbnails' strip, so the clips' mask cuts them as it cuts the take's thumbnails: a frozen frame's frame over its
/// whole length (the take's thumbnail of its point, from the `ThumbnailCache`), an imported clip's frames on the take's
/// grid (`ContentClipTrackRules.tiles`, from `MediaClipFrames`), a title card tinted with its title; each with its
/// symbol. A frame not made yet leaves the clip's color; one that leaves the sight before it is made is cancelled. The
/// last 200 frames are kept.
@MainActor
final class TimelineContentClipsRow {
    /// Over the thumbnails' strip (a sublayer of it, in its coordinates).
    let layer = CALayer()
    private let decorations: LayerPool<ContentClipLayer>
    private let tiles: LayerPool<CALayer>
    /// The project's imported clips (`TimelineViewController.makeCaches`): another one forgets what was read.
    var frames: MediaClipFrames? {
        didSet { forgetFrames() }
    }
    /// Called once a frame or a clip's length arrived, to draw it.
    var arrived: () -> Void = {}

    private enum FrameKey: Hashable {
        case take(track: String, source: UInt64, height: Int)
        case media(asset: String, time: UInt64, height: Int)
    }
    /// What was made, `nil` when there is none, oldest first.
    private var images: [FrameKey: CGImage?] = [:]
    private var order: [FrameKey] = []
    private var loading: [FrameKey: Task<Void, Never>] = [:]
    private var wanted: Set<FrameKey> = []
    /// The frame each tile shows, or is waiting for.
    private var tileKeys: [String: FrameKey] = [:]
    /// What each imported clip is, once read (`nil` inside: it cannot be read), and the reads under way.
    private var infos: [String: MediaInfo?] = [:]
    private var probing: [String: Task<Void, Never>] = [:]
    private var tint: (background: CGColor, increaseContrast: Bool, tint: TimelinePalette.Tint)?
    private static var symbols: [String: CGImage] = [:]
    private static let keptFrames = 200
    /// The narrowest piece of a thumbnail drawn, as the take's.
    private static let narrowestTile = 16.0

    init() {
        layer.zPosition = 1
        tiles = LayerPool(parent: layer) {
            let tile = CALayer()
            tile.contentsGravity = .left
            tile.masksToBounds = true
            return tile
        }
        decorations = LayerPool(parent: layer) {
            let decoration = ContentClipLayer()
            decoration.zPosition = 1
            return decoration
        }
    }

    func begin() {
        decorations.begin()
        tiles.begin()
        wanted = []
    }

    /// The end of a pass: what is no longer in sight is not made.
    func end() {
        decorations.end()
        tiles.end()
        for (key, task) in loading where !wanted.contains(key) {
            task.cancel()
            loading[key] = nil
        }
    }

    /// Forgets the layers and the colors (the appearance changed).
    func reset() {
        decorations.removeAll()
        tiles.removeAll()
        tileKeys = [:]
        tint = nil
    }

    /// Forgets the frames and the clips read (another project, or the package moved).
    func forgetFrames() {
        stop()
        images = [:]
        order = []
        tileKeys = [:]
        infos = [:]
        tiles.removeAll()
    }

    /// Nothing more is made (the window closed, or nothing is shown).
    func stop() {
        for task in loading.values { task.cancel() }
        loading = [:]
        for task in probing.values { task.cancel() }
        probing = [:]
    }

    var layerCount: Int { decorations.shownCount + tiles.shownCount }

    /// The length of the file of imported clip `asset`, once it was read; `nil` before (it is read then) or if it cannot
    /// be read.
    func fileDuration(of asset: String) -> Int64? {
        guard let known = infos[asset] else {
            probe(asset)
            return nil
        }
        return known?.duration
    }

    /// Lays out the clips with content of `content` in sight, in the strip `height` points high.
    func layOut(
        _ content: TimelineContent, _ geometry: TimelineGeometry, _ palette: TimelinePalette, height: Double,
        selected: Set<String>, settling: Bool, thumbnails: ThumbnailCache?
    ) {
        layer.frame = CGRect(x: 0, y: 0, width: geometry.areaWidth, height: height)
        guard !content.contentClips.isEmpty, height > 0 else { return }
        let (lower, upper) = geometry.visibleOutput
        let pixels = min(max(Int((height * geometry.backingScale).rounded()), 1), 512)
        let tint = tint(palette)
        content.clips.forEach(from: lower, to: upper) { item in
            guard let info = content.contentClips.info(item.id),
                let rect = geometry.itemRect(item.output, top: 0, height: height, gap: 1)
            else { return }
            layOutTiles(info, content, geometry, height: height, pixels: pixels, visible: lower..<max(upper, lower), thumbnails: thumbnails)
            let (decoration, isNew) = decorations.layer(item.id)
            if isNew {
                decoration.label.contentsScale = geometry.backingScale
                decoration.icon.contentsScale = geometry.backingScale
                decoration.symbol = nil
                decoration.symbolColor = nil
                decoration.labelText = nil
            }
            Self.place(decoration, rect, isNew: isNew, settling: settling)
            let symbol = TimelineContentClipItems.symbol(info.kind)
            var title: String?
            let color: CGColor
            if case let .card(cardTitle) = info.kind {
                // A tinted block: no frame to show.
                decoration.backgroundColor = selected.contains(item.id) ? tint.selectedFill : tint.fill
                decoration.badge.backgroundColor = nil
                decoration.label.foregroundColor = tint.text
                color = tint.text
                title = cardTitle ?? String(localized: "Title Card", comment: "A clip of the sequence that shows a title over the whole frame")
            } else {
                // Over a frame, the symbol on a dark badge, as a clip's speed is.
                decoration.backgroundColor = nil
                decoration.badge.backgroundColor = palette.badgeFill
                color = palette.badgeText
            }
            if decoration.symbol != symbol || decoration.symbolColor != color {
                decoration.symbol = symbol
                decoration.symbolColor = color
                decoration.icon.contents = Self.symbolImage(symbol, scale: geometry.backingScale, color: color)
            }
            if decoration.labelText != title {
                decoration.labelText = title
                decoration.label.string = title
            }
            // The symbol and the title stay at the left of what is in sight.
            let left = max(3, -rect.minX + 3)
            let right = min(rect.width, geometry.areaWidth - rect.minX) - 4
            decoration.badge.frame = CGRect(x: left, y: 3, width: 16, height: 14)
            decoration.icon.frame = CGRect(x: 2.5, y: 1.5, width: 11, height: 11)
            decoration.badge.isHidden = rect.width < 22
            decoration.label.isHidden = title == nil || right - left - 18 < 24
            decoration.label.frame = CGRect(x: left + 18, y: 3, width: max(right - left - 18, 0), height: 13)
        }
    }

    /// The thumbnails of a frozen frame or an imported clip in sight, each the frame at its left edge from its left, or
    /// the clip's color until it arrives (never a frame of another time).
    private func layOutTiles(
        _ info: TimelineContentClipItems.Info, _ content: TimelineContent, _ geometry: TimelineGeometry, height: Double,
        pixels: Int, visible: Range<Int64>, thumbnails: ThumbnailCache?
    ) {
        let aspect: Double
        let key: (UInt64) -> FrameKey?
        switch info.kind {
        case .card:
            return
        case let .freeze(point, thumbnailed):
            guard thumbnailed, thumbnails != nil, let track = content.screenTrack(atSource: point.nanoseconds) else { return }
            aspect = content.screenAspect
            key = { .take(track: track, source: $0, height: pixels) }
        case let .media(asset):
            guard frames != nil else { return }
            guard let known = infos[asset] else {
                // Its frames are laid out once its proportion is known.
                probe(asset)
                return
            }
            guard let size = known?.size, size.x > 0, size.y > 0 else { return }
            aspect = min(max(Double(size.x) / Double(size.y), 0.5), 3)
            key = { .media(asset: asset, time: $0, height: pixels) }
        }
        let inSight = ContentClipTrackRules.tiles(
            of: info.clip, outputStart: info.outputStart, visible: visible, scale: geometry.scale,
            tileWidth: (height * aspect).rounded(), minimumWidth: Self.narrowestTile)
        for tile in inSight {
            guard let frameKey = key(tile.frame) else { continue }
            wanted.insert(frameKey)
            let id = "\(info.clip.id) \(tile.index)"
            let (layer, isNew) = tiles.layer(id)
            if isNew { layer.contentsScale = geometry.backingScale }
            let minX = geometry.snapped(geometry.x(tile.output)), maxX = geometry.snapped(geometry.x(tile.end))
            layer.frame = CGRect(x: minX, y: 0, width: maxX - minX, height: height)
            if isNew || tileKeys[id] != frameKey {
                tileKeys[id] = frameKey
                layer.contents = nil
            }
            if let made = images[frameKey] {
                if layer.contents == nil, let made { layer.contents = made }
            } else {
                request(frameKey, thumbnails: thumbnails)
            }
        }
    }

    private func request(_ key: FrameKey, thumbnails: ThumbnailCache?) {
        guard loading[key] == nil else { return }
        let frames = frames
        loading[key] = Task { [weak self] in
            let image: CGImage?
            switch key {
            case let .take(track, source, height):
                image = await thumbnails?.thumbnail(track: track, source: HostTime(nanoseconds: source), height: height)
            case let .media(asset, time, height):
                image = await frames?.frame(asset, at: time, height: height)
            }
            guard !Task.isCancelled, let self else { return }
            self.loading[key] = nil
            self.keep(key, image)
            self.arrived()
        }
    }

    private func keep(_ key: FrameKey, _ image: CGImage?) {
        if images.updateValue(image, forKey: key) == nil { order.append(key) }
        if order.count > Self.keptFrames {
            images[order.removeFirst()] = nil
        }
    }

    /// Reads what `asset` is, once.
    private func probe(_ asset: String) {
        guard infos[asset] == nil, probing[asset] == nil, let frames else { return }
        probing[asset] = Task { [weak self] in
            let info = await frames.info(asset)
            guard !Task.isCancelled, let self else { return }
            self.probing[asset] = nil
            self.infos[asset] = .some(info)
            self.arrived()
        }
    }

    /// A title card's hue, indigo as the captions' (the texts of the timeline), made opaque over the timeline's background.
    private func tint(_ palette: TimelinePalette) -> TimelinePalette.Tint {
        if let tint, tint.background == palette.background, tint.increaseContrast == palette.increaseContrast { return tint.tint }
        let background = NSColor(cgColor: palette.background)?.usingColorSpace(.sRGB) ?? .black
        let dark = background.brightnessComponent < 0.5
        var made: TimelinePalette.Tint?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let hue = NSColor.systemIndigo.usingColorSpace(.sRGB) ?? .systemIndigo
            func over(_ fraction: CGFloat) -> CGColor { (background.blended(withFraction: fraction, of: hue) ?? hue).cgColor }
            let text = dark ? hue.blended(withFraction: 0.6, of: .white) ?? .white : hue.blended(withFraction: 0.55, of: .black) ?? .black
            made = TimelinePalette.Tint(
                fill: over(dark ? 0.42 : 0.30), selectedFill: over(dark ? 0.58 : 0.46), stroke: hue.cgColor, text: text.cgColor)
        }
        let result = made ?? TimelinePalette.Tint(
            fill: palette.clipFill, selectedFill: palette.clipFill, stroke: palette.separator, text: palette.label)
        self.tint = (palette.background, palette.increaseContrast, result)
        return result
    }

    /// Puts `layer` at `rect`; settling, it goes there from where it was with `Motion.trackItem`.
    private static func place(_ layer: CALayer, _ rect: CGRect, isNew: Bool, settling: Bool) {
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

    /// The symbol in `color`, at the clips' text size, for a display of `scale` pixels per point.
    private static func symbolImage(_ name: String, scale: Double, color: CGColor) -> CGImage? {
        let key = "\(name)@\(scale) \(color.components ?? [])"
        if let image = symbols[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: color) ?? .white]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        let drawn = image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scaleByX: scale, byY: scale)])
        if let drawn { symbols[key] = drawn }
        return drawn
    }
}

// MARK: - Dropping a clip on the Video track

/// A video file dragged from Finder over the Video track (phase 3 design §5.4): while it is over the track, a line at the
/// edge of the clip under it where it would go in (`ContentClipCommands.insertionPoint`, the nearer edge, nothing split);
/// dropped, it is copied into the project (`EditSession.importAsset`, which reads and hashes it on the session's queue of
/// files, off the main thread) with "Importing «name»…" at the timeline's bottom left meanwhile (where its notices are),
/// then put into the sequence at the edge nearest where it was dropped in the document as it is then
/// (`ContentClipCommands.addMedia`), selected. One at a time; a file that does not play says "Couldn't open the file.".
@MainActor
final class TimelineMediaDrop {
    private unowned let view: EditorTimelineView
    private let line = CALayer()
    private let label = CATextLayer()
    private var importing: Task<Void, Never>?

    init(view: EditorTimelineView) {
        self.view = view
        line.cornerRadius = 1
        line.isHidden = true
        line.zPosition = 3
        label.cornerRadius = 4
        label.alignmentMode = .center
        label.isHidden = true
        label.zPosition = 3
        TimelineText.setUp(label, size: 11, weight: .medium)
        view.overlay.addSublayer(line)
        view.overlay.addSublayer(label)
    }

    /// What a drag over the timeline can do: copy a clip onto the Video track, with the line where it would go.
    func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard importing == nil, let target = target(sender) else {
            hide()
            return []
        }
        show(target.line)
        return .copy
    }

    /// The file was dropped: it is imported, and goes into the sequence.
    func perform(_ sender: any NSDraggingInfo) -> Bool {
        guard importing == nil, let target = target(sender), let model = view.interaction.model, let session = model.panelSession
        else {
            hide()
            return false
        }
        let name = target.url.lastPathComponent
        let text = String(format: String(localized: "Importing “%@”…", comment: "Over the timeline, while a clip dropped on the Video track is copied into the project"), name)
        showProgress(text)
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [.announcement: text])
        let (url, τ) = (target.url, target.output)
        importing = Task { [weak self] in
            let outcome = await session.importAsset(url, kind: .video)
            var failed = false
            if !Task.isCancelled {
                switch outcome {
                case let .imported(path): failed = !(await model.addMediaClip(asset: path, nearOutput: τ))
                case .notPlayable, .notAnImage, .notALUT: failed = true
                // The session says why it could not be saved; a project that cannot be edited is said by its banner.
                case .saveFailed, .notEditable: break
                }
            }
            guard let self else { return }
            self.importing = nil
            self.hide()
            if failed, !Task.isCancelled { self.view.interaction.showNotice(String(localized: "Couldn't open the file.")) }
        }
        return true
    }

    /// The drag left, or ended: the line goes (and the label, unless a clip is being imported, which it says).
    func hide() {
        guard importing == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.isHidden = true
        label.isHidden = true
        CATransaction.commit()
    }

    /// The window closed: an import under way gives up.
    func stop() {
        importing?.cancel()
    }

    /// The file dragged and where it would go: one video file (`ContentClipTrackRules.isVideoFile`) over the Video track
    /// of a document that can be edited; the line at its edge, in the area's coordinates.
    private func target(_ sender: any NSDraggingInfo) -> (url: URL, output: Int64, line: CGRect)? {
        guard let model = view.interaction.model, model.canEdit, let document = model.document, let content = view.content,
            let geometry = view.geometry(), let row = geometry.rows.first(where: { $0.track == .video })
        else { return nil }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard urls.count == 1, let url = urls.first, ContentClipTrackRules.isVideoFile(url) else { return nil }
        let point = view.convert(sender.draggingLocation, from: nil)
        let top = TimelineLayout.rulerHeight + row.top - geometry.verticalOffset
        guard point.x >= TimelineLayout.headerWidth, point.y >= top, point.y < top + row.height else { return nil }
        let τ = content.layout.output(atX: point.x, scale: geometry.scale, offset: geometry.offset)
        guard case let .output(edge) = ContentClipCommands.insertionPoint(document, nearOutput: τ) else { return nil }
        let x = geometry.snapped(geometry.x(edge))
        return (url, τ, CGRect(x: x - 1, y: top + 1, width: 2, height: row.height - 2))
    }

    private func show(_ rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.backgroundColor = view.palette.selection
        line.frame = rect
        line.opacity = 1
        line.isHidden = false
        CATransaction.commit()
    }

    /// While the clip is imported: the line goes (the timeline may scroll meanwhile), the label stays where the notices are.
    private func showProgress(_ text: String) {
        let palette = view.palette
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.isHidden = true
        label.string = text
        label.foregroundColor = palette.dragLabelText
        label.backgroundColor = palette.dragLabelFill
        label.contentsScale = Double(view.window?.backingScaleFactor ?? 2)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        let area = max(view.bounds.width - TimelineLayout.headerWidth, 0)
        let width = min((text as NSString).size(withAttributes: attributes).width.rounded(.up) + 16, max(area - 16, 40))
        label.frame = CGRect(x: 8, y: max(view.bounds.height - 30, 0), width: width, height: 22)
        label.isHidden = false
        CATransaction.commit()
    }
}

// MARK: - The menu

extension TimelineInteraction {
    /// "Freeze Frame" and "Add Title Card" at output instant `τ`, in a clip's menu (phase 3 design §5.2, §5.3).
    func addContentInsertItems(to menu: NSMenu, at τ: Int64) {
        guard let model, let document = model.document else { return }
        let freeze = ContentClipMenuItem(String(localized: "Freeze Frame")) { model.freezeFrame(atOutput: τ) }
        freeze.isEnabled = model.canEdit && ContentClipCommands.freeze(document, atOutput: τ, makeID: EditorModel.newID) != nil
        menu.addItem(freeze)
        let card = ContentClipMenuItem(String(localized: "Add Title Card")) { model.addTitleCard(atOutput: τ) }
        card.isEnabled = model.canEdit
        menu.addItem(card)
    }

    /// The menu of a clip with content (plan 3a Task A15): Duration… of a frozen frame or a title card, Freeze Frame (off:
    /// nothing is frozen inside one), Add Title Card (at its nearer edge) and Delete. `window` is where Duration… asks.
    func addContentClipItems(to menu: NSMenu, _ info: TimelineContentClipItems.Info, at τ: Int64, window: NSWindow?) {
        guard let model else { return }
        if ContentClipTrackRules.drag(for: .end, of: info.clip) == .duration {
            let duration = ContentClipMenuItem(String(localized: "Duration…", comment: "The menu of a frozen frame or a title card of the Video track: asks for its length")) { [weak self] in
                self?.askDuration(of: info.clip.id, window: window)
            }
            duration.isEnabled = model.canEdit
            menu.addItem(duration)
            menu.addItem(.separator())
        }
        addContentInsertItems(to: menu, at: τ)
        menu.addItem(.separator())
        let delete = ContentClipMenuItem(String(localized: "Delete")) { [weak self] in self?.deleteSelected() }
        delete.isEnabled = model.canEdit
        menu.addItem(delete)
    }

    /// "Duration…": a sheet that asks for the length of frozen frame or title card `id`, in seconds from 0.1 to 60.
    func askDuration(of id: String, window: NSWindow?) {
        guard let model, let window, let clip = model.document?.sequence.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Duration")
        alert.informativeText = String(localized: "From 0.1 to 60 s.", comment: "Duration… of a frozen frame or a title card: the lengths it takes")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        // In the user's language ("2,5"), to the hundredth: left as it is, nothing changes.
        let shown = TimelineFormat.number((Double(TimeMap.outputDuration(of: clip)) / 1e7).rounded() / 100)
        field.stringValue = shown
        field.setAccessibilityLabel(String(localized: "Seconds", comment: "The field of Duration…: a length in seconds"))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, typed != shown, let duration = ContentClipTrackRules.duration(fromTyped: typed)
            else { return }
            MainActor.assumeIsolated { model.setContentDuration(id, duration) }
        }
    }
}

/// A menu item that runs a closure.
private final class ContentClipMenuItem: NSMenuItem {
    private let body: () -> Void

    init(_ title: String, _ body: @escaping () -> Void) {
        self.body = body
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError()
    }

    @objc private func run() {
        body()
    }
}

// MARK: - The model's steps

extension EditorModel {
    /// "Freeze Frame" of a clip's menu, at output instant `τ` (`ContentClipCommands.freeze`): the frozen frame is the one
    /// selected.
    func freezeFrame(atOutput τ: Int64) {
        guard canEdit, !isGesturing, let document,
            let step = ContentClipCommands.freeze(document, atOutput: τ, makeID: Self.newID), perform(step) != .refused
        else { return }
        selection = .clips([step.target])
    }

    /// "Add Title Card" of a clip's menu, at output instant `τ` (inside a clip with content, at its nearer edge), titled
    /// "Title": the card is the one selected.
    func addTitleCard(atOutput τ: Int64) {
        guard canEdit, !isGesturing, let document,
            let step = ContentClipCommands.addCard(
                document, at: .output(τ), title: String(localized: "Title"), makeID: Self.newID),
            perform(step) != .refused
        else { return }
        selection = .clips([step.target])
    }

    /// The length of frozen frame or title card `id` (Duration…), held to 0.1 … 60 s.
    func setContentDuration(_ id: String, _ duration: Int64) {
        guard canEdit, let document, let step = ContentClipCommands.setDuration(document, clipID: id, duration) else { return }
        perform(step)
    }

    /// The imported clip `asset` (`assets/<sha>.<ext>`, as `importAsset` named it) into the sequence at the edge of the
    /// clip nearest output instant `τ` in the document as it is now (`ContentClipCommands.insertionPoint`), the whole of
    /// its file, read off the main thread (`MediaInfo.probe`): it is the one selected. False if its file cannot be read
    /// or lasts less than a frame (nothing changes); true otherwise, also when the project can no longer be edited.
    func addMediaClip(asset: String, nearOutput τ: Int64) async -> Bool {
        guard let package = overlayProject?.package, let info = await MediaInfo.probe(asset, in: package) else { return false }
        guard canEdit, let document else { return true }
        guard let step = ContentClipCommands.addMedia(
            document, asset: asset, fileDuration: info.duration, at: ContentClipCommands.insertionPoint(document, nearOutput: τ),
            makeID: Self.newID)
        else { return false }
        if perform(step) != .refused { selection = .clips([step.target]) }
        return true
    }
}

#if DEBUG
extension EditorModel {
    /// `TOMA_SHOWCASE_P3_ANNOTATIONS=content` (Task A15): a title card "Intro" at the start, a frozen frame at 6 s of the
    /// output, and the take's own first segment of its screen imported as a clip, at the end; the frozen frame selected.
    func showcaseContentClips() async {
        guard let document, let step = ContentClipCommands.addCard(document, at: .start, title: "Intro", makeID: Self.newID)
        else { return }
        perform(step)
        guard let document = self.document,
            let freeze = ContentClipCommands.freeze(document, atOutput: TimeMap.outputNanoseconds(seconds: 6), makeID: Self.newID),
            perform(freeze) != .refused
        else { return }
        selection = .clips([freeze.target])
        guard let project = overlayProject, let session = panelSession,
            let segment = project.take.tracks.first(where: { $0.kind.isScreen && !$0.segments.isEmpty })?.segments.first,
            case let .imported(path) = await session.importAsset(project.package.url.appending(path: segment.file), kind: .video),
            let end = self.document.map({ TimeMap(sequence: $0.sequence).duration })
        else { return }
        _ = await addMediaClip(asset: path, nearOutput: end)
        selection = .clips([freeze.target])
    }
}
#endif
