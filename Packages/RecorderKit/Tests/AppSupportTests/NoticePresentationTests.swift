// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Testing

@Suite struct NoticePresentationTests {
    @Test func noticePresentationClassifiesEveryCase() {
        // The take stopped by itself, or closed with an error: red.
        #expect(TakeNotice.stoppedForDiskSpace.presentation == .stopped)
        #expect(TakeNotice.closedWithError.presentation == .stopped)
        // A source that came back: a capsule of two seconds.
        #expect(TakeNotice.streamResumed(.display).presentation == .confirmation)
        #expect(TakeNotice.streamResumed(.microphone).presentation == .confirmation)
        // Everything else asks for attention: amber.
        let attention: [TakeNotice] = [
            .noMicrophone, .microphoneAccessOff, .microphoneFailedToStart, .cameraNotRecordedYet, .cameraAccessOff,
            .streamInterrupted(.display), .trackLost(.microphone), .screenPaused, .trackPaused(.microphone),
            .writerFailed(.display), .samplesDropped(.microphone), .manifestWriteFailed, .diskLow(availableBytes: 1),
            .diskSpaceUnknown, .couldNotMoveToTrash, .microphoneSilent,
        ]
        for notice in attention {
            #expect(notice.presentation == .attention, "\(notice)")
        }
    }

    @Test func confirmationsShowForTwoSeconds() {
        #expect(IslandConfirmation.displayDuration == .seconds(2))
    }
}
