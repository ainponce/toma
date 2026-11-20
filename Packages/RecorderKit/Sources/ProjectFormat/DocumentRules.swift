// SPDX-License-Identifier: GPL-3.0-or-later

/// A rule of the document of phase 3 that a document breaks (phase 3 design §10, base plan decision 6), and of phases 4
/// and 5 (fases 4 y 5 design §4.1). The editor refuses a step that leaves one, and a document with one, edited by hand,
/// opens read-only, shown as it can be drawn.
public enum DocumentProblem: Equatable, Sendable {
    /// A clip with content whose `end` is not its `start`: a clip with content is a point of its take.
    case contentNotAPoint(clip: String)
    /// A clip that starts before the end of a clip of its take before it (`SequenceRules.firstOutOfOrder(in:)`).
    case outOfOrder(clip: String)
    /// A clip whose `audioShift` is out of `SequenceRules.audioShiftRange(of:at:)`.
    case audioShiftOutOfRange(clip: String)
    /// A frozen frame or a title card of a duration out of `ClipContent.durationRange`, or an imported clip whose end
    /// is at or before its start.
    case contentDuration(clip: String)
    /// The path of a file named by a clip, an annotation or a theme that is not a file of its kind in `assets/`
    /// (`DocumentRules.isAssetPath(_:as:)`: a video for an imported clip and a clip annotation, an image for an image
    /// annotation), or a theme's source that is neither a sound there nor one of the library
    /// (`DocumentRules.isMusicSource`).
    case assetOutsideAssets(String)
    /// A clip annotation anchored to the take (`AnnotationAnchor.content`): it plays in the output only.
    case clipAnnotationAnchoredToContent(annotation: String)
    /// The project's `title` or `summary` (`field`) longer than `ProjectInfo.titleLimit` or `summaryLimit` characters.
    case infoTooLong(field: String)
}

/// The rules of the document of phases 3, 4 and 5 beyond its decoding (phase 3 design §10, base plan decision 6; fases 4
/// y 5 design §4.1): what the editor's `isDrawable` refuses.
public enum DocumentRules {
    /// What `document` breaks, in this order: for each clip of the sequence, a clip with content that is not a point, its
    /// content's duration and its asset, and its cut of the sound; the clips out of order; each annotation's asset and a
    /// clip annotation anchored to the take; each theme's source; the project's title and its summary. Empty for every
    /// document of phases 1 and 2 whose sequence is in order.
    public static func problems(in document: EditDocument) -> [DocumentProblem] {
        var problems: [DocumentProblem] = []
        let sequence = document.sequence
        for (k, clip) in sequence.enumerated() {
            if let content = clip.content {
                if clip.start != clip.end { problems.append(.contentNotAPoint(clip: clip.id)) }
                switch content {
                case let .freeze(duration), let .card(_, duration):
                    if !ClipContent.durationRange.contains(duration) { problems.append(.contentDuration(clip: clip.id)) }
                case let .media(media):
                    if media.end <= media.start { problems.append(.contentDuration(clip: clip.id)) }
                    if !isAssetPath(media.asset, as: .video) { problems.append(.assetOutsideAssets(media.asset)) }
                }
            }
            if clip.audioShift != 0, !SequenceRules.audioShiftRange(of: sequence, at: k).contains(clip.audioShift) {
                problems.append(.audioShiftOutOfRange(clip: clip.id))
            }
        }
        problems += SequenceRules.outOfOrder(in: sequence).map { .outOfOrder(clip: sequence[$0].id) }
        for annotation in document.annotations.items {
            switch annotation.kind {
            case let .image(image):
                if !isAssetPath(image.asset, as: .asset) { problems.append(.assetOutsideAssets(image.asset)) }
            case let .clip(clip):
                if !isAssetPath(clip.asset, as: .video) { problems.append(.assetOutsideAssets(clip.asset)) }
                if case .content = annotation.anchor { problems.append(.clipAnnotationAnchoredToContent(annotation: annotation.id)) }
            case .text, .arrow, .shape, .callout, .step:
                break
            }
        }
        for item in document.music.items where !isMusicSource(item.source) {
            problems.append(.assetOutsideAssets(item.source))
        }
        if let info = document.info {
            if info.title.count > ProjectInfo.titleLimit { problems.append(.infoTooLong(field: "title")) }
            if info.summary.count > ProjectInfo.summaryLimit { problems.append(.infoTooLong(field: "summary")) }
        }
        return problems
    }

    /// Whether `path` names a file of `kind` of the package's `assets/`: `assets/` and a name of that kind
    /// (`PackageFileKind.isValidName`: `.asset` an image, `.video` a clip, `.audio` a sound, `.lut` a `.cube`), as its
    /// reader reads it. `false` for a kind whose files are not in `assets/`.
    public static func isAssetPath(_ path: String, as kind: PackageFileKind) -> Bool {
        switch kind {
        case .asset, .lut, .video, .audio: break
        case .cursorImage, .wallpaper, .script: return false
        }
        let prefix = "assets/"
        guard path.hasPrefix(prefix) else { return false }
        return kind.isValidName(String(path.dropFirst(prefix.count)))
    }

    /// Whether `source` is what a theme can play: one of the library, `library:music-1/` and an id of ASCII letters,
    /// digits and `-`, or a sound of `assets/` (`isAssetPath(_:as:)` with `.audio`).
    public static func isMusicSource(_ source: String) -> Bool {
        if isAssetPath(source, as: .audio) { return true }
        let musicLibraryPrefix = "library:music-1/"
        guard source.hasPrefix(musicLibraryPrefix) else { return false }
        let id = source.utf8.dropFirst(musicLibraryPrefix.utf8.count)
        return !id.isEmpty && id.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }
}
