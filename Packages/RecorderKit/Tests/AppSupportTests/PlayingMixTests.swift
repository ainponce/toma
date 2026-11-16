// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import Testing

/// Revisions of the legacy document of a take of 30 s of one display.
private enum Revisions {
    static let take = TakeRecord(
        id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display, source: TrackSource(name: "Display", displayID: 1),
                segments: [
                    SegmentRecord(
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: HostTime(nanoseconds: 1_000),
                        endHostTime: HostTime(nanoseconds: 1_000).adding(seconds: 30), endReason: .stopped, droppedFrames: 0,
                        heartbeatFrames: 0)
                ])
        ])

    static let opened = EditDocument.legacy(take: take, events: [])

    /// The first 10 s cut.
    static var cut: EditDocument {
        var document = opened
        document.sequence[0].start = document.sequence[0].start.adding(seconds: 10)
        return document
    }

    /// Another background: nothing of the sound.
    static var background: EditDocument {
        var document = opened
        document.style.background = .color(RGBA(0.2, 0.3, 0.4, 1))
        return document
    }

    static var quieter: EditDocument {
        var document = opened
        document.audio.tracks["take-001/mic"] = TrackGain(gain: 0.5, muted: false)
        return document
    }

    static var otherFrameRate: EditDocument {
        var document = opened
        document.frameRate = 30
        return document
    }

    static var clicking: EditDocument {
        var document = opened
        document.cursor.clickSound = document.cursor.clickSound == "soft-1" ? "mechanical-1" : "soft-1"
        return document
    }
}

@Suite struct PlayingMixTests {
    @Test func whatTheMixReads() {
        let opened = Revisions.opened
        #expect(!PlayingMix.soundDiffers(opened, opened))
        #expect(!PlayingMix.soundDiffers(opened, Revisions.background))
        #expect(PlayingMix.soundDiffers(opened, Revisions.cut))
        #expect(PlayingMix.soundDiffers(opened, Revisions.quieter))
        #expect(PlayingMix.soundDiffers(opened, Revisions.otherFrameRate))
        #expect(PlayingMix.soundDiffers(opened, Revisions.clicking))
    }

    /// An edit made before the project's first mix is made, played meanwhile on the host's clock: the mix of the
    /// opening revision arrives, then that of the edit, which has to be played.
    @Test func anEditBeforeTheFirstMixIsHeardOnceItsMixArrives() {
        var mix = PlayingMix()
        // Playing without a player: nothing held, nothing to play.
        #expect(!mix.needsPlay)
        // The player is made with the opening revision's mix while the edit's is being built: the model does not play
        // it (it would be the wrong sound), so nothing is heard.
        mix.hold(Revisions.opened)
        #expect(mix.heard == nil)
        // The edit's mix: nothing is heard yet, so it is played.
        mix.hold(Revisions.cut)
        #expect(mix.needsPlay)
        mix.played()
        #expect(mix.heard == Revisions.cut && !mix.needsPlay)
    }

    /// Paused, an edit, then Space before its mix is built: the player plays the mix it holds, the one before the edit,
    /// so the edit's has to be played once it arrives.
    @Test func playingBeforeAnEditsMixArrivesPlaysItOnceItDoes() {
        var mix = PlayingMix()
        mix.hold(Revisions.opened)
        mix.played()
        mix.stopped()
        // The cut is made, paused; Space: the player still holds the opening revision's mix.
        mix.played()
        #expect(mix.heard == Revisions.opened && !mix.needsPlay)
        mix.hold(Revisions.cut)
        #expect(mix.needsPlay)
        mix.played()
        #expect(!mix.needsPlay)
        // A change of volume while playing: played again.
        var quieter = Revisions.cut
        quieter.audio.tracks["take-001/mic"] = TrackGain(gain: 0.5, muted: false)
        mix.hold(quieter)
        #expect(mix.needsPlay)
    }

    /// A change that the sound does not read (the background) is not played again: no gap in the sound.
    @Test func anEditThatSoundsTheSameIsNotPlayedAgain() {
        var mix = PlayingMix()
        mix.hold(Revisions.opened)
        mix.played()
        mix.hold(Revisions.background)
        #expect(!mix.needsPlay)
        // Stopped, or a sound that did not start: played again when asked.
        mix.stopped()
        #expect(mix.needsPlay)
    }
}
