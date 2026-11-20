// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The sound of the imported clips (phase 3 design §5.4 and §13, step 2): those of the sequence (`ClipContent.media`) and
/// those over it (`AnnotationKind.clip`), each read from its file of `assets/` (`ProjectPackage.mediaAsset(_:as:)`,
/// `AudioTrackTimeline.load(file:id:channels:)`). `EditedMix` adds it after the tracks and the clicks, before the music
/// and the limiter.
///
/// The base of phase 3 has none (base plan task B9): `make` gives `none`, which has no sound, so the mix is phase 2's.
/// Plan 3a (A10) fills it.
struct MediaAudio: Sendable {
    /// No imported clip to hear.
    static let none = MediaAudio()

    private init() {}

    /// The sound of the imported clips of `document` of `project`, at the frames `timeMap` gives them, with `channels`
    /// channels (the mix's): opens their files, off the main thread.
    static func make(project: LoadedProject, document: EditDocument, timeMap: TimeMap, channels: Int) async -> MediaAudio {
        .none
    }

    /// Whether any imported clip sounds: without, `add` adds nothing.
    var hasSound: Bool { false }

    /// Adds the sound of the imported clips over output frames `frames` into `samples`, which holds those frames,
    /// interleaved with `channels` channels, from `frames.lowerBound`. The mix keeps only what falls within its content.
    /// Called with `EditedMix.render`'s lock held.
    func add(_ frames: Range<Int64>, into samples: inout [Float], channels: Int) {}
}
