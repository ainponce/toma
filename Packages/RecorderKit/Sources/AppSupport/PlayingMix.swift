// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Which revision's sound the preview's player holds and which one is heard, so an edit is heard while playing (design
/// §7.7). The player takes a new mix (`setMix`) only from its next `play`: while it plays, the revision heard is the one
/// it held when it was last asked to play, whatever revision the playhead is counted in. Each revision's mix comes
/// later than the revision (it is built off the main thread), and the project's first one later still.
public struct PlayingMix: Sendable {
    /// The document whose mix the player holds: the last one given to it.
    public private(set) var held: EditDocument?
    /// The document whose mix is heard, while the player plays; `nil` while it does not (stopped, not started, or its
    /// sound could not start).
    public private(set) var heard: EditDocument?

    public init() {}

    /// The player was made with, or given (`setMix`), the mix of `document`.
    public mutating func hold(_ document: EditDocument) {
        held = document
    }

    /// The player was asked to play: it plays the mix it holds.
    public mutating func played() {
        heard = held
    }

    /// The player stopped, or its sound did not start: nothing of it is heard.
    public mutating func stopped() {
        heard = nil
    }

    /// While playing, whether the player has to be asked to play again (from the clock) for the mix it holds to be
    /// heard: nothing is heard yet, or what is heard sounds otherwise. `false` while it holds no mix.
    public var needsPlay: Bool {
        guard let held else { return false }
        guard let heard else { return true }
        return Self.soundDiffers(heard, held)
    }

    /// Whether `new` sounds otherwise than `old`: they differ in what the mix reads (`EditedMix`): the clips, the frames
    /// per second, the audio plan, or the click sound and its volume.
    public static func soundDiffers(_ old: EditDocument, _ new: EditDocument) -> Bool {
        old.sequence != new.sequence || old.frameRate != new.frameRate || old.audio != new.audio
            || old.cursor.clickSound != new.cursor.clickSound || old.cursor.clickSoundGain != new.cursor.clickSoundGain
    }
}
