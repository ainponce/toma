// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Recording

/// The user's controls over the take being recorded: pause, markers and restart.
extension RecordingController {
    /// Pauses the take being recorded, or resumes it if the user paused it. `isUserPaused` changes at once,
    /// and goes back to what the take last accepted if the take refuses (it is closing). The time recorded
    /// stops when the take really pauses (`RecordedTime` follows the take's `paused` and `resumed`).
    public func togglePause() {
        guard case .recording = phase, let recording = take?.recording else { return }
        let pausing = !isUserPaused
        isUserPaused = pausing
        pendingPauseRequests += 1
        send(
            to: recording, pausing ? "pause" : "resume",
            then: { [weak self] accepted in self?.pauseReturned(pausing: pausing, accepted: accepted, from: recording) }
        ) { recording in
            if pausing { try await recording.pause() } else { try await recording.resume() }
        }
    }

    /// Once every pause and resume sent has returned, `isUserPaused` is what the take last accepted. A
    /// pause the take accepted is confirmed, unless the user has asked to resume since.
    private func pauseReturned(pausing: Bool, accepted: Bool, from recording: any TakeRecording) {
        guard take?.recording === recording else { return }
        if accepted { acceptedUserPause = pausing }
        pendingPauseRequests -= 1
        if pendingPauseRequests == 0 { isUserPaused = acceptedUserPause }
        if accepted, pausing, isUserPaused { onConfirmation(.paused) }
    }

    /// Marks this moment of the take being recorded. Nothing is written while the take is paused. A marker
    /// the take wrote is confirmed, and counted in the saved take.
    public func addMarker() {
        guard case .recording = phase, !isUserPaused, !isPaused, let recording = take?.recording else { return }
        send(
            to: recording, "marker",
            then: { [weak self] accepted in
                guard let self, accepted, take?.recording === recording else { return }
                markersWritten += 1
                onConfirmation(.markerAdded)
            }
        ) { recording in _ = try await recording.addMarker() }
    }

    /// Sends `request` once the requests sent before it have returned, so they reach the take in order, and
    /// then tells whether the take accepted it. A take that is closing refuses it.
    private func send(
        to recording: any TakeRecording, _ name: String, then returned: @escaping @MainActor (_ accepted: Bool) -> Void = { _ in },
        _ request: @escaping @Sendable (any TakeRecording) async throws -> Void
    ) {
        let previous = userRequests
        userRequests = Task {
            await previous?.value
            do {
                try await request(recording)
                returned(true)
            } catch {
                Self.logger.notice("The take refused the \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                returned(false)
            }
        }
    }

    /// Closes the take being recorded without opening it, moves its project to the trash (and confirms it)
    /// and records a new take of the same request, in a new project, after counting down again. What the
    /// restart could not do is said in the notices: a take that closed with an error is kept
    /// (`closedWithError`), and so is one that could not be moved (`couldNotMoveToTrash`); the new take
    /// starts either way. A take the disk stopped is kept and saved as the disk's stop would, and nothing
    /// new starts; so does a stop that comes while the take closes, as that stop would.
    public func restartTake() {
        guard case .recording = phase, stopTask == nil, let take, let request = currentRequest else { return }
        isRestarting = true
        stopDuringRestart = nil
        stopTask = Task { await restart(take, request: request) }
    }

    private func restart(_ take: Take, request: TakeRequest) async {
        // Before the phase leaves `.recording`.
        let recorded = recordedTime.elapsed(at: environment.now())
        setPhase(.stopping)
        let closed = await closeAndHear(take)
        isRestarting = false
        // The disk won if it stopped the take, whichever close came first.
        let endedForDiskSpace = autoStopped
            || closed.record?.tracks.contains { $0.segments.contains { $0.endReason == .diskFull } } == true
        if endedForDiskSpace || stopDuringRestart != nil {
            // Kept, as a stop would: the stops that came waited for this one, so the take is saved here, once,
            // as they asked (the disk's own stop follows the settings), or as the disk's stop when none came.
            // Quitting saves nothing and opens no editor, also when the disk stopped the take.
            finish(take, closed, as: stopDuringRestart ?? savingAsTheSettingsSay(), recorded: recorded)
            return
        }
        // From here to the new start nothing suspends, so a stop either came before or finds the new start.
        releaseTake()
        var carried: [TakeNotice] = []
        if let error = closed.error {
            // Closed in part: kept where it is.
            lastCloseError = error
            carried.append(.closedWithError)
            lastProjectURL = take.package.url
        } else if closed.opened {
            do {
                // A rename on the same volume: quick enough for the main actor.
                let trashed = try ProjectTrash.move(take.package, projectsFolder: environment.projectsFolder)
                Self.logger.notice("Moved the restarted take to \(trashed.path, privacy: .public)")
                onConfirmation(.movedToTrash)
            } catch {
                Self.logger.error("Cannot move \(take.package.url.path, privacy: .public) to the trash: \(String(describing: error), privacy: .public)")
                carried.append(.couldNotMoveToTrash)
                lastProjectURL = take.package.url
            }
        }
        stopTask = nil
        // The new take's notices start as `carried`.
        begin(request, carrying: carried, restarting: true)
    }
}
