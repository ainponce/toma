// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
import ProjectFormat

// Phase 3 base, Task B4 (design §9): every take of the package in `LoadedProject`, each take's events read once and
// shared by the copies and the focused values, and a track's gain by its id in every take.

/// `LoadedProject.takeEvents`, counting its calls by take.
private final class CountingReader: Sendable {
    private let counts = Mutex<[String: Int]>([:])

    var reads: [String: Int] { counts.withLock { $0 } }

    var read: LoadedProject.EventsReader {
        { package, take in
            self.counts.withLock { $0[take, default: 0] += 1 }
            return try LoadedProject.takeEvents(package, take)
        }
    }
}

@Suite struct LoadedProjectTakesTests {
    /// The events of `take` as the event log reader reads them.
    private static func logged(_ take: String, of project: LoadedProject) throws -> [InputEvent] {
        try EventLogReader.read(take: take, of: project.package).events
    }

    @Test func loadReadsEveryTakeOnce() async throws {
        try await withTemporaryDirectory { dir in
            let made = try await MultiTakeFixtures.twoTakes(in: dir)
            let url = made.package.url
            let project = try LoadedProject.load(url)
            #expect(project.take.id == "take-002")
            #expect(project.takes == project.manifest.takes)
            #expect(project.takes.map(\.id) == ["take-001", "take-002"])
            // The second take raises the package to 5 (phase 3 design §11) and leaves the first take as it was written.
            #expect(project.manifest.formatVersion == 5)
            #expect(project.takes[0].tracks.map(\.id) == ["display-1", "mic"])
            #expect(project.takes[1].tracks.map(\.id) == ["display-1", "mic"])
            let first = try Self.logged("take-001", of: project)
            let second = try Self.logged("take-002", of: project)
            #expect(!first.isEmpty && !second.isEmpty && first != second)
            #expect(project.events == second)
            #expect(project.events(ofTake: "take-001") == first)
            #expect(project.events(ofTake: "take-002") == second)

            // Deferred: no log is read until one is asked for, then each once for every copy and focused value, however
            // many ask at the same time.
            let counter = CountingReader()
            let deferred = try LoadedProject.load(url, take: nil, deferringEvents: counter.read)
            #expect(counter.reads.isEmpty)
            let copies = (0..<8).map { _ in deferred }
            let results = await withTaskGroup(of: [[InputEvent]].self) { group in
                for (index, copy) in copies.enumerated() {
                    group.addTask {
                        let focused = copy.focused(on: index.isMultiple(of: 2) ? "take-001" : "take-002")
                        return [
                            copy.events, copy.events(ofTake: "take-001"), focused?.events ?? [],
                            focused?.events(ofTake: "take-002") ?? [], copy.focused(on: "take-001")?.events ?? [],
                        ]
                    }
                }
                var all: [[[InputEvent]]] = []
                for await result in group { all.append(result) }
                return all
            }
            #expect(counter.reads == ["take-001": 1, "take-002": 1])
            for result in results {
                #expect(result[0] == second)
                #expect(result[1] == first)
                #expect(result[2] == first || result[2] == second)
                #expect(result[3] == second)
                #expect(result[4] == first)
            }
            // A focused value and its copies keep sharing them.
            let focused = try #require(deferred.focused(on: "take-001"))
            let again = try #require(focused.focused(on: "take-002")?.focused(on: "take-001"))
            #expect(again.events == first)
            #expect(focused.takesShown(by: MultiTakeFixtures.sequence(of: focused, [("take-002", 0, 1)]))[0].events == second)
            #expect(counter.reads == ["take-001": 1, "take-002": 1])
        }
    }

    @Test func focusedSharesTheEvents() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let focused = try #require(project.focused(on: "take-001"))
            #expect(focused.take == project.takes[0])
            #expect(focused.take.id == "take-001")
            #expect(focused.takes == project.takes)
            #expect(focused.package.url == project.package.url)
            #expect(focused.manifest == project.manifest)
            #expect(focused.events == project.events(ofTake: "take-001"))
            #expect(focused.events == (try Self.logged("take-001", of: project)))
            #expect(focused.events(ofTake: "take-002") == project.events)
            #expect(try #require(focused.focused(on: "take-002")).events == project.events)
            // Its own take is itself, events set on it included, and so are the values focused from it afterwards; its
            // copies keep theirs.
            var edited = project
            let one = [InputEvent(t: HostTime(nanoseconds: 7), kind: .marker)]
            edited.events = one
            #expect(edited.focused(on: "take-002")?.events == one)
            #expect(edited.events(ofTake: "take-002") == one)
            #expect(edited.focused(on: "take-001")?.events(ofTake: "take-002") == one)
            #expect(edited.focused(on: "take-001")?.focused(on: "take-002")?.events == one)
            #expect(edited.takesShown(by: MultiTakeFixtures.sequence(of: edited, [("take-001", 0, 1), ("take-002", 0, 1)]))
                .map(\.events) == [project.events(ofTake: "take-001"), one])
            #expect(project.events(ofTake: "take-002") == (try Self.logged("take-002", of: project)))
            #expect(project.focused(on: "take-001")?.events(ofTake: "take-002") == project.events)
            var focused001 = focused
            focused001.events = one
            #expect(focused001.focused(on: "take-002")?.focused(on: "take-001")?.events == one)
            #expect(focused.events == (try Self.logged("take-001", of: project)))
            // A take the manifest does not have.
            #expect(project.focused(on: "take-009") == nil)
            #expect(project.events(ofTake: "take-009") == [])
        }
    }

    @Test func anUnreadableSecondTakeDoesNotStopTheProject() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let url = project.package.url
            let events = project.package.eventsURL(take: "take-001")
            let second = try Self.logged("take-002", of: project)

            // A link, even to a good log: never followed.
            try FileManager.default.removeItem(at: events)
            try FileManager.default.createSymbolicLink(at: events, withDestinationURL: project.package.eventsURL(take: "take-002"))
            for loaded in [try LoadedProject.load(url), try LoadedProject.load(url, take: nil, deferringEvents: LoadedProject.takeEvents)] {
                #expect(loaded.events == second)
                #expect(loaded.events(ofTake: "take-001") == [])
                let focused = try #require(loaded.focused(on: "take-001"))
                #expect(focused.events == [])
                #expect(throws: POSIXError(.ELOOP)) { try focused.readEvents() }
            }

            // A FIFO: never opened, so never waited on.
            try FileManager.default.removeItem(at: events)
            #expect(mkfifo(events.path, 0o644) == 0)
            let withFifo = try LoadedProject.load(url)
            #expect(withFifo.events(ofTake: "take-001") == [])
            #expect(throws: POSIXError(.EFTYPE)) { try withFifo.focused(on: "take-001")?.readEvents() }

            // No log as the package loads: a take without events.
            try FileManager.default.removeItem(at: events)
            let without = try LoadedProject.load(url)
            #expect(without.events(ofTake: "take-001") == [])
            try #require(without.focused(on: "take-001")).readEvents()
            #expect(without.events == second)
        }
    }

    @Test func aLogGoneSinceTheLoadIsAnErrorForEveryTake() async throws {
        try await withTemporaryDirectory { dir in
            // As `load(_:take:deferringEvents:)` says of the take loaded: there when the package loaded and gone when the
            // events are asked for (the package moved meanwhile) is an error, never a take without one.
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let url = project.package.url
            let first = try Self.logged("take-001", of: project)
            for loaded in [
                try LoadedProject.load(url), try LoadedProject.load(url, take: nil, deferringEvents: LoadedProject.takeEvents),
                try LoadedProject.load(url, take: nil, lookingAtEvents: LoadedProject.takeEvents),
            ] {
                let elsewhere = dir.appending(path: "moved.toma", directoryHint: .isDirectory)
                try FileManager.default.moveItem(at: url, to: elsewhere)
                let focused = try #require(loaded.focused(on: "take-001"))
                #expect(throws: POSIXError(.ENOENT)) { try focused.readEvents() }
                #expect(throws: POSIXError(.ENOENT)) { try focused.checkEvents() }
                #expect(loaded.events(ofTake: "take-001") == [])
                try FileManager.default.moveItem(at: elsewhere, to: url)
                // Read before, they stay.
                let again = try LoadedProject.load(url)
                #expect(again.events(ofTake: "take-001") == first)
                try FileManager.default.moveItem(at: url, to: elsewhere)
                #expect(again.events(ofTake: "take-001") == first)
                try FileManager.default.moveItem(at: elsewhere, to: url)
            }
        }
    }

    @Test func lookingAtEventsRefusesNoTakeAtOnce() async throws {
        try await withTemporaryDirectory { dir in
            // For who does not know yet which take it shows: the take loaded's log is looked at as the others' are.
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let url = project.package.url
            let events = project.package.eventsURL(take: "take-002")
            let first = try Self.logged("take-001", of: project)
            try FileManager.default.removeItem(at: events)
            #expect(mkfifo(events.path, 0o644) == 0)
            #expect(throws: POSIXError(.EFTYPE)) { try LoadedProject.load(url) }
            #expect(throws: POSIXError(.EFTYPE)) {
                try LoadedProject.load(url, take: nil, deferringEvents: LoadedProject.takeEvents)
            }
            let counter = CountingReader()
            let lazy = try LoadedProject.load(url, take: nil, lookingAtEvents: counter.read)
            #expect(lazy.take.id == "take-002")
            #expect(throws: POSIXError(.EFTYPE)) { try lazy.checkEvents() }
            #expect(throws: POSIXError(.EFTYPE)) { try lazy.readEvents() }
            #expect(lazy.events == [])
            let shown = try #require(lazy.focused(on: "take-001"))
            try shown.checkEvents()
            #expect(counter.reads.isEmpty)
            try shown.readEvents()
            #expect(shown.events == first)
            // The FIFO was never opened: only take-001's log was read.
            #expect(counter.reads == ["take-001": 1])
        }
    }

    @Test func takesShownFollowTheSequence() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let both = MultiTakeFixtures.sequence(
                of: project, [("take-002", 0, 1), ("take-001", 0.5, 1.5), ("take-002", 1.5, 2.5)])
            #expect(project.takesShown(by: both).map(\.take.id) == ["take-002", "take-001"])
            #expect(project.takesShown(by: both).map(\.events) == [project.events, project.events(ofTake: "take-001")])

            var unknown = both
            unknown.sequence[1].take = "take-009"
            #expect(project.takesShown(by: unknown).map(\.take.id) == ["take-002"])
            unknown.sequence[0].take = "take-009"
            unknown.sequence[2].take = "take-009"
            #expect(project.takesShown(by: unknown).isEmpty)

            let onlyFirst = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 4)])
            #expect(project.takesShown(by: onlyFirst).map(\.take.id) == ["take-001"])

            var empty = both
            empty.sequence = []
            #expect(project.takesShown(by: empty).map(\.take.id) == ["take-002"])
            let focused = try #require(project.focused(on: "take-001"))
            #expect(focused.takesShown(by: empty).map(\.take.id) == ["take-001"])
        }
    }

    @Test func sequenceOfTwoTakesShowsEachTakeAsItsOwnLegacy() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await MultiTakeFixtures.twoTakes(in: dir)
            let first = try #require(project.focused(on: "take-001"))
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0.5, 2.5)])
            let legacy = EditDocument.legacy(for: project), firstLegacy = EditDocument.legacy(for: first)
            let start1 = try #require(firstLegacy.sequence.first?.start), start2 = try #require(legacy.sequence.first?.start)
            #expect(document.sequence == [
                Clip(id: "c-00000001", take: "take-001", start: start1, end: start1.adding(seconds: 2), speed: 1),
                Clip(id: "c-00000002", take: "take-002", start: start2.adding(seconds: 0.5), end: start2.adding(seconds: 2.5), speed: 1),
            ])
            #expect(document.screens.initial == ["take-001": "display-1", "take-002": "display-1"])
            #expect(document.camera.initial.keys.sorted() == ["take-001", "take-002"])
            // The gains stay the project's take's: the other take's tracks are found by their id.
            #expect(document.audio == legacy.audio)
            var same = document
            same.sequence = legacy.sequence
            same.screens = legacy.screens
            same.camera = legacy.camera
            #expect(same == legacy)
        }
    }

    @Test func trackGainByIDHoldsInEveryTake() {
        let own = TrackGain(gain: 0.5, muted: false)
        let other = TrackGain(gain: 1.5, muted: true, cleanup: 0.4)
        let plan = AudioPlan(limiter: false, tracks: [
            "take-001/mic": own, "take-002/mic": other, "take-003/mic": TrackGain(gain: 2, muted: false),
            "take-002/system-audio": other,
        ])
        let takes = ["take-003", "take-002", "take-001", "take-004"]
        // Its own key wins.
        #expect(plan.trackGain(take: "take-001", track: "mic", takes: takes) == own)
        #expect(plan.trackGain(take: "take-002", track: "mic", takes: takes) == other)
        // Without one, the same track's in the first take of the sequence that has it.
        #expect(plan.trackGain(take: "take-004", track: "mic", takes: takes)?.gain == 2)
        #expect(plan.trackGain(take: "take-004", track: "mic", takes: ["take-004", "take-001", "take-003"]) == own)
        #expect(plan.trackGain(take: "take-001", track: "system-audio", takes: takes) == other)
        // No take has it.
        #expect(plan.trackGain(take: "take-001", track: "camera-audio", takes: takes) == nil)
        #expect(plan.trackGain(take: "take-004", track: "mic", takes: ["take-004", "take-005"]) == nil)
        #expect(plan.trackGain(take: "take-004", track: "mic", takes: []) == nil)
        // One take: its own or none, as `tracks` reads it.
        #expect(plan.trackGain(take: "take-001", track: "mic", takes: ["take-001"]) == own)
        #expect(plan.trackGain(take: "take-001", track: "system-audio", takes: ["take-001"]) == nil)
        #expect(plan.trackGain(take: "take-001", track: "mic", takes: ["take-001"]) == plan.tracks[AudioPlan.key(take: "take-001", track: "mic")])
    }
}
