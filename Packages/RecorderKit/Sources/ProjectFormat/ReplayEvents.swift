// SPDX-License-Identifier: GPL-3.0-or-later

/// The `events.jsonl` of a saved Replay (fases 4 y 5 design §10.3, plan 5c decisions 6 and 7).
public enum ReplayEvents {
    /// The events of the saved take and its first camera style.
    ///
    /// `carried` (the state of the event files pruned already) and `events` (those of the files left) are put in time
    /// order, the ones at the same time in that order; what comes before `cut.start` is folded into the state
    /// (`ReplayEventState`) and what falls in `[cut.start, cut.end]` is kept, but for:
    /// - the events of a track that is not saved;
    /// - those of the life of a track's segments (`segmentStarted`, `audioClock`, `droppedSamples`, `streamInterrupted`,
    ///   `deviceChanged`) before its first segment saved or after the end of its last one, which name segments not saved
    ///   (an `audioClock` there would anchor a saved file with another file's frames);
    /// - a `segmentStarted` of a segment not saved; the others get their new index (`cut.renumbered`).
    ///
    /// The state re-emitted at `cut.start` (`ReplayEventState.reEmitted(at:)`, without the windows of tracks not saved)
    /// comes first, and then what is kept. The camera style is the one in force at `cut.start`, and `nil` when no
    /// camera track is saved.
    public static func saved(
        _ events: [InputEvent], carried: [InputEvent], initialCameraStyle: CameraStyle?, cut: ReplayCut
    ) -> (events: [InputEvent], cameraStyle: CameraStyle?) {
        let all = (carried + events).sortedByTime()
        let savedTracks = Set(cut.tracks.map(\.id))
        var spans: [String: ClosedRange<HostTime>] = [:]
        for track in cut.tracks {
            guard let first = track.segments.first, let last = track.segments.last?.endHostTime else { continue }
            spans[track.id] = first.startHostTime...max(first.startHostTime, last)
        }

        var state = ReplayEventState(cameraStyle: initialCameraStyle)
        state.fold(all.filter { $0.t < cut.start })
        var kept: [InputEvent] = []
        for event in all where cut.start <= event.t && event.t <= cut.end {
            guard let track = event.kind.track else {
                kept.append(event)
                continue
            }
            guard savedTracks.contains(track) else { continue }
            if event.kind.isSegmentLife {
                guard let span = spans[track], span.contains(event.t) else { continue }
            }
            if case let .segmentStarted(_, index) = event.kind {
                guard let new = cut.renumbered[track]?[index] else { continue }
                kept.append(InputEvent(t: event.t, kind: .segmentStarted(track: track, index: new)))
                continue
            }
            kept.append(event)
        }

        let reEmitted = state.reEmitted(at: cut.start).filter { event in
            event.kind.track.map(savedTracks.contains) ?? true
        }
        let hasCamera = cut.tracks.contains { $0.kind == .camera }
        return (reEmitted + kept, hasCamera ? state.cameraStyle : nil)
    }
}

extension InputEvent.Kind {
    /// The track an event names, if it names one.
    fileprivate var track: String? {
        switch self {
        case let .segmentStarted(track, _), let .streamInterrupted(track, _, _), let .deviceChanged(track, _),
             let .droppedSamples(track, _), let .audioClock(track, _), let .windowGeometry(track, _, _):
            track
        case .cursor, .mouseDown, .mouseUp, .displayGeometry, .paused, .resumed, .marker, .cameraStyle, .cursorImage,
             .scroll, .keyActivity, .keyPress, .focus:
            nil
        }
    }

    /// Whether it tells of the life of a segment of its track.
    fileprivate var isSegmentLife: Bool {
        switch self {
        case .segmentStarted, .audioClock, .droppedSamples, .streamInterrupted, .deviceChanged: true
        default: false
        }
    }
}
