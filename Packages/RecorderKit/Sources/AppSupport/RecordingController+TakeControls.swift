// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Recording

/// The user's controls over the take being recorded: pause, markers and restart.
extension RecordingController {
    /// Pauses the take being recorded, or resumes it if the user paused it. The time recorded stops when
    /// the take really pauses (`RecordedTime` follows the take's `paused` and `resumed`).
    public func togglePause() {
        guard case .recording = phase, let recording = take?.recording else { return }
        let pausing = !isUserPaused
        isUserPaused = pausing
        send(to: recording, pausing ? "pause" : "resume") { recording in
            if pausing { try await recording.pause() } else { try await recording.resume() }
        }
    }

    /// Marks this moment of the take being recorded. Nothing is written while the take is paused.
    public func addMarker() {
        guard case .recording = phase, !isUserPaused, !isPaused, let recording = take?.recording else { return }
        send(to: recording, "marker") { recording in _ = try await recording.addMarker() }
    }

    /// Sends `request` once the requests sent before it have returned, so they reach the take in order. A
    /// take that is closing refuses it.
    private func send(
        to recording: any TakeRecording, _ name: String, _ request: @escaping @Sendable (any TakeRecording) async throws -> Void
    ) {
        let previous = userRequests
        userRequests = Task {
            await previous?.value
            do {
                try await request(recording)
            } catch {
                Self.logger.notice("The take refused the \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Closes the take being recorded without opening it, moves its project to the trash and records a new
    /// take of the same request, in a new project. What the restart could not do is said in the notices:
    /// a take that closed with an error is kept (`closedWithError`), and so is one that could not be moved
    /// (`couldNotMoveToTrash`); the new take starts either way. A take the disk stopped is kept and opened,
    /// and nothing new starts; so does a stop that comes while the take closes.
    public func restartTake() {
        guard case .recording = phase, stopTask == nil, let take, let request = currentRequest else { return }
        isRestarting = true
        stopDuringRestart = nil
        stopTask = Task { await restart(take, request: request) }
    }

    private func restart(_ take: Take, request: TakeRequest) async {
        setPhase(.stopping)
        let closed = await closeAndHear(take)
        isRestarting = false
        // The disk won if it stopped the take, whichever close came first.
        let endedForDiskSpace = autoStopped
            || closed.record?.tracks.contains { $0.segments.contains { $0.endReason == .diskFull } } == true
        if endedForDiskSpace || stopDuringRestart != nil {
            // Kept, as a stop would: the stops that came waited for this one, so the editor opens here, once,
            // if they asked for it (the disk's own stop does), or for the disk when none came. Quitting asks
            // for no editor, also when the disk stopped the take.
            finish(take, closed, openingEditor: stopDuringRestart ?? endedForDiskSpace)
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
            } catch {
                Self.logger.error("Cannot move \(take.package.url.path, privacy: .public) to the trash: \(String(describing: error), privacy: .public)")
                carried.append(.couldNotMoveToTrash)
                lastProjectURL = take.package.url
            }
        }
        notices = carried
        stopTask = nil
        begin(request, carrying: carried)
    }
}
