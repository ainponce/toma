// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Export
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// @testable for the library of test themes (`init(root:themes:score:synthesize:scratch:)`) and what it counts.
@testable import ProjectJobs

// Every test here runs in `make tsan`. The themes are short scores (a loop of 1 s, rendered with its 8 s of tail and no
// reverb), so a synthesis takes a moment even in a debug build under the thread sanitizer.

/// A loop of one bar of 2/4 at 120 BPM (1 s): a pad and a pluck.
private let testTheme = MusicScore(
    id: "calm", tempo: 120, beatsPerBar: 2, bars: 1, seed: 11,
    parts: [
        ScorePart(instrument: .pad(.soft), notes: [ScoreNote(beat: 0, beats: 2, pitch: 60, velocity: 0.6)], gain: 0.5),
        ScorePart(instrument: .pluck(.harp), notes: [ScoreNote(beat: 0.5, beats: 0.5, pitch: 72, velocity: 0.7)], gain: 0.5),
    ],
    reverb: .none, delay: nil, masterGain: 0.8, isPlaceholder: false)
private let testFrames = 48_000

/// A library in `root` whose one theme, `calm`, is `theme`, with its placeholders in `scratch`.
private func makeLibrary(
    _ root: URL, theme: MusicScore = testTheme, scratch: URL? = nil,
    synthesize: (@Sendable (MusicScore, () -> Bool) -> [Float]?)? = nil
) -> MusicLibrary {
    let score: @Sendable (String) -> MusicScore? = { $0 == "calm" ? theme : nil }
    if let synthesize { return MusicLibrary(root: root, themes: ["calm"], score: score, synthesize: synthesize, scratch: scratch) }
    return MusicLibrary(root: root, themes: ["calm"], score: score, scratch: scratch)
}

/// Long enough for a loaded machine under the thread sanitizer: `eventually` returns as soon as it holds.
private let patience = Duration.seconds(60)

/// Where a synthesis waits until the test opens it, or until it is told to stop; it says when one arrived.
private final class Gate: Sendable {
    private let state = Mutex((open: false, arrivals: 0, stopped: 0))

    var arrivals: Int { state.withLock { $0.arrivals } }
    var stopped: Int { state.withLock { $0.stopped } }

    func open() { state.withLock { $0.open = true } }

    /// Waits (on the library's queue, which may block) until opened — then renders — or until `isCancelled`.
    func synthesize(_ score: MusicScore, _ isCancelled: () -> Bool) -> [Float]? {
        state.withLock { $0.arrivals += 1 }
        while !state.withLock({ $0.open }) {
            if isCancelled() {
                state.withLock { $0.stopped += 1 }
                return nil
            }
            usleep(1_000)
        }
        return MusicSynth.render(score, until: isCancelled)
    }
}

/// The names in `folder`, hidden ones included; none if it is not there.
private func names(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

@Suite struct MusicLibraryTests {
    @Test func aThemeIsSynthesizedOnceAndKept() async throws {
        try await withTemporaryDirectory { root in
            let library = makeLibrary(root)
            #expect(library.cachedFile(for: "calm") == nil)
            let url = try await library.file(for: "calm")
            #expect(url == root.appending(path: "music-1/calm-\(testTheme.fingerprint).caf"))
            #expect(testTheme.fingerprint.count == 16)
            #expect(try await library.file(for: "calm") == url)
            #expect(await library.syntheses == 1)
            #expect(library.cachedFile(for: "calm") == url)
            let expected = MusicFile.data(interleaved: try await offThePool { MusicSynth.render(testTheme) })
            #expect(try Data(contentsOf: url) == expected)
            #expect(names(in: url.deletingLastPathComponent()) == [url.lastPathComponent])
            // A new library on the same folder finds it.
            let again = makeLibrary(root)
            #expect(try await again.file(for: "calm") == url)
            #expect(await again.syntheses == 0)
        }
    }

    @Test func concurrentCallersShareOneSynthesis() async throws {
        try await withTemporaryDirectory { root in
            let gate = Gate()
            let library = makeLibrary(root, synthesize: gate.synthesize)
            try await withThrowingTaskGroup(of: URL.self) { group in
                for _ in 0..<8 {
                    group.addTask { try await library.file(for: "calm") }
                }
                #expect(await eventually(timeout: patience) { await library.waiters(for: "calm") == 8 })
                gate.open()
                var urls: [URL] = []
                for try await url in group { urls.append(url) }
                #expect(urls.count == 8)
                #expect(Set(urls) == [library.url(for: "calm")])
            }
            #expect(gate.arrivals == 1)
            #expect(await library.syntheses == 1)
            #expect(library.cachedFile(for: "calm") != nil)
        }
    }

    @Test func aDeletedThemeIsMadeAgain() async throws {
        try await withTemporaryDirectory { root in
            let library = makeLibrary(root)
            let url = try await library.file(for: "calm")
            let first = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            #expect(library.cachedFile(for: "calm") == nil)
            #expect(try await library.file(for: "calm") == url)
            #expect(await library.syntheses == 2)
            #expect(try Data(contentsOf: url) == first)
            // Even with its folder gone.
            try FileManager.default.removeItem(at: root.appending(path: "music-1"))
            #expect(try await library.file(for: "calm") == url)
            #expect(try Data(contentsOf: url) == first)
        }
    }

    @Test func aCancelledSynthesisLeavesNoFile() async throws {
        try await withTemporaryDirectory { root in
            let gate = Gate()
            let library = makeLibrary(root, synthesize: gate.synthesize)
            let caller = Task { try await library.file(for: "calm") }
            #expect(await eventually(timeout: patience) { gate.arrivals == 1 })
            caller.cancel()
            await #expect(throws: CancellationError.self) { try await caller.value }
            #expect(await eventually(timeout: patience) { await library.inFlight == 0 })
            #expect(gate.stopped == 1)
            #expect(names(in: root.appending(path: "music-1")) == [])
            #expect(library.cachedFile(for: "calm") == nil)
            // The next caller starts anew.
            gate.open()
            let url = try await library.file(for: "calm")
            #expect(library.cachedFile(for: "calm") == url)
            // The cancelled one does not count.
            #expect(await library.syntheses == 1)
        }
    }

    @Test func oneCancelledCallerLeavesTheOthersTheirTheme() async throws {
        try await withTemporaryDirectory { root in
            let gate = Gate()
            let library = makeLibrary(root, synthesize: gate.synthesize)
            let leaving = Task { try await library.file(for: "calm") }
            let staying = Task { try await library.file(for: "calm") }
            #expect(await eventually(timeout: patience) { await library.waiters(for: "calm") == 2 })
            leaving.cancel()
            #expect(await eventually(timeout: patience) { await library.waiters(for: "calm") == 1 })
            gate.open()
            await #expect(throws: CancellationError.self) { try await leaving.value }
            let url = try await staying.value
            #expect(url == library.url(for: "calm"))
            #expect(gate.stopped == 0)
            #expect(await library.syntheses == 1)
        }
    }

    @Test func aBadFileIsNotTheTheme() async throws {
        try await withTemporaryDirectory { root in
            let library = makeLibrary(root)
            let url = library.url(for: "calm")
            let good = MusicFile.data(interleaved: try await offThePool { MusicSynth.render(testTheme) })
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Cut short.
            try good.prefix(good.count - 8).write(to: url)
            #expect(library.cachedFile(for: "calm") == nil)
            #expect(try await library.file(for: "calm") == url)
            #expect(try Data(contentsOf: url) == good)

            // Our CAF, but of another length.
            try MusicFile.data(interleaved: [Float](repeating: 0, count: 2 * (testFrames + 1))).write(to: url)
            #expect(library.cachedFile(for: "calm") == nil)

            // A link, even to the theme itself, is not followed: it is replaced, and what it pointed to is left alone.
            try FileManager.default.removeItem(at: url)
            let elsewhere = root.appending(path: "elsewhere.caf")
            try good.write(to: elsewhere)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: elsewhere)
            #expect(library.cachedFile(for: "calm") == nil)
            #expect(try await library.file(for: "calm") == url)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            #expect(values.isSymbolicLink == false && values.isRegularFile == true)
            #expect(try Data(contentsOf: url) == good)
            #expect(try Data(contentsOf: elsewhere) == good)
            #expect(await library.syntheses == 2)
        }
    }

    @Test func anUnknownThemeIsAnError() async throws {
        try await withTemporaryDirectory { root in
            let library = makeLibrary(root)
            await #expect(throws: MusicLibraryError.unknownTheme("rain")) { try await library.file(for: "rain") }
            #expect(library.cachedFile(for: "rain") == nil)
            // Its name still stays in the folder.
            #expect(library.url(for: "../../x").deletingLastPathComponent() == root.appending(path: "music-1/"))
            #expect(library.url(for: "../../x").lastPathComponent == "______x.caf")
        }
    }

    @Test func aChangedScoreIsNotTheCachedTheme() async throws {
        try await withTemporaryDirectory { root in
            let old = try await makeLibrary(root).file(for: "calm")
            // The app updated: the theme sounds otherwise (here, louder), and its cache is the old one.
            var tuned = testTheme
            tuned.masterGain = 0.9
            #expect(tuned.fingerprint != testTheme.fingerprint)
            let library = makeLibrary(root, theme: tuned)
            #expect(library.cachedFile(for: "calm") == nil)
            let url = try await library.file(for: "calm")
            #expect(url != old)
            #expect(await library.syntheses == 1)
            let now = tuned
            let expected = MusicFile.data(interleaved: try await offThePool { MusicSynth.render(now) })
            #expect(try Data(contentsOf: url) == expected)
            // The old version is gone; only the theme as it is now is kept.
            #expect(names(in: root.appending(path: "music-1")) == [url.lastPathComponent])
            // A change to a single note is a change too.
            var moved = tuned
            moved.parts[1].notes[0].pitch += 1
            #expect(moved.fingerprint != tuned.fingerprint)
            #expect(makeLibrary(root, theme: moved).cachedFile(for: "calm") == nil)
        }
    }

    @Test func aPlaceholderIsNeverCached() async throws {
        try await withTemporaryDirectory { root in
            var placeholder = testTheme
            placeholder.isPlaceholder = true
            let scratch = root.appending(path: "scratch-1")
            var library: MusicLibrary? = makeLibrary(root, theme: placeholder, scratch: scratch)
            let url = try #require(try await library?.file(for: "calm"))
            #expect(url.path.hasPrefix(scratch.path))
            #expect(library?.cachedFile(for: "calm") == url)
            #expect(names(in: root.appending(path: "music-1")) == [])
            // Another library (the app's next launch) does not find it, and makes it again where it keeps its own.
            let next = makeLibrary(root, theme: placeholder, scratch: root.appending(path: "scratch-2"))
            #expect(next.cachedFile(for: "calm") == nil)
            // The library that made it removes it when it goes.
            library = nil
            #expect(await eventually(timeout: patience) { !FileManager.default.fileExists(atPath: scratch.path) })
        }
    }

    @Test func theAppsLibraryIsInItsCaches() throws {
        #expect(MusicLibrary.defaultRoot.path.hasSuffix("/Library/Caches/dev.toma.Toma/Music"))
        let breeze = try #require(MusicThemes.score("breeze"))
        let url = MusicLibrary.shared.url(for: "breeze")
        #expect(url.lastPathComponent == "breeze-\(breeze.fingerprint).caf")
        if breeze.isPlaceholder {
            #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        } else {
            #expect(url == MusicLibrary.defaultRoot.appending(path: "music-1/breeze-\(breeze.fingerprint).caf"))
        }
    }
}
