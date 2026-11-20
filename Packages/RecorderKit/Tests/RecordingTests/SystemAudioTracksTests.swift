// SPDX-License-Identifier: GPL-3.0-or-later
import CoreAudio
import Darwin
import Foundation
import ProjectFormat
import SyntheticCapture
import Testing

@testable import Recording

// Phase 3 (plan 3c, Task U9, decision 1; design §7.1): By App records each chosen app in a track of its own, at most 8,
// each with its app in the manifest.

@Suite struct SystemAudioTracksTests {
    private let own = "dev.toma.Toma"

    @Test func everyAppGetsItsTrack() {
        #expect(SystemAudioTracks.plan(.applications(["com.apple.Safari", "com.spotify.client"]), ownBundleIdentifier: own) == [
            SystemAudioTrackPlan(
                trackID: "system-audio-com-apple-Safari", scope: .applications(["com.apple.Safari"]), appBundleID: "com.apple.Safari",
                otherApplications: ["com.spotify.client"]),
            SystemAudioTrackPlan(
                trackID: "system-audio-com-spotify-client", scope: .applications(["com.spotify.client"]),
                appBundleID: "com.spotify.client", otherApplications: ["com.apple.Safari"]),
        ])
        // All of the system stays one track, as in phase 2; By App with no app, one track of silence.
        #expect(SystemAudioTracks.plan(.all, ownBundleIdentifier: own)
            == [SystemAudioTrackPlan(trackID: "system-audio", scope: .all, appBundleID: nil)])
        #expect(SystemAudioTracks.plan(.applications([]), ownBundleIdentifier: own)
            == [SystemAudioTrackPlan(trackID: "system-audio", scope: .applications([]), appBundleID: nil)])
        // An app chosen twice is one track: two would record it twice.
        #expect(SystemAudioTracks.plan(.applications(["com.apple.Music", "", "com.apple.Music"]), ownBundleIdentifier: own).map(\.trackID)
            == ["system-audio-com-apple-Music"])
        #expect(SystemAudioTracks.maximumTracks == 8)
    }

    @Test func moreThanEightShareTheLast() {
        let apps = (1...10).map { "com.example.app\($0)" }
        let plan = SystemAudioTracks.plan(.applications(apps), ownBundleIdentifier: own)
        #expect(plan.count == 8)
        #expect(plan.prefix(7) == ArraySlice(apps.prefix(7).map { app in
            SystemAudioTrackPlan(
                trackID: "system-audio-" + app.replacingOccurrences(of: ".", with: "-"), scope: .applications([app]), appBundleID: app,
                otherApplications: apps.filter { $0 != app })
        }))
        #expect(plan.last == SystemAudioTrackPlan(
            trackID: "system-audio", scope: .applications(["com.example.app8", "com.example.app9", "com.example.app10"]), appBundleID: nil,
            otherApplications: Array(apps.prefix(7))))
        // Eight are eight tracks of their own.
        let eight = SystemAudioTracks.plan(.applications(Array(apps.prefix(8))), ownBundleIdentifier: own)
        #expect(eight.count == 8 && eight.allSatisfy { $0.appBundleID != nil })
        // Toma and the exclusions do not count toward the 8.
        let nine = SystemAudioTracks.plan(.applications(Array(apps.prefix(8)) + [own, "systemsoundserverd"]), ownBundleIdentifier: own)
        #expect(nine.count == 8 && nine.allSatisfy { $0.appBundleID != nil })
    }

    @Test func collidingIDsGetASuffix() {
        let plan = SystemAudioTracks.plan(.applications(["com.a-b", "com.a.b", "com.A.b"]), ownBundleIdentifier: own)
        #expect(plan.map(\.trackID) == ["system-audio-com-a-b", "system-audio-com-a-b-2", "system-audio-com-A-b-3"])
        #expect(plan.map(\.appBundleID) == ["com.a-b", "com.a.b", "com.A.b"])
        let odd = SystemAudioTracks.plan(.applications(["com.exämple/app 1"]), ownBundleIdentifier: own)
        #expect(odd.map(\.trackID) == ["system-audio-com-ex-mple-app-1"])
        // Only letters, digits and "-": a track id a reader of phase 2 takes.
        for track in plan + odd {
            #expect(track.trackID.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") })
        }
    }

    @Test func tomaAndTheExclusionsGetNoTrack() {
        let plan = SystemAudioTracks.plan(
            .applications([own, "com.apple.Safari", "systemsoundserverd", "com.apple.notificationcenterui"]), ownBundleIdentifier: own)
        #expect(plan.map(\.appBundleID) == ["com.apple.Safari"])
        // Only those: the one track of silence.
        #expect(SystemAudioTracks.plan(.applications([own, "systemsoundserverd"]), ownBundleIdentifier: own)
            == [SystemAudioTrackPlan(trackID: "system-audio", scope: .applications([]), appBundleID: nil)])
        // Without a bundle of its own (a command-line tool), nothing of that is left out.
        #expect(SystemAudioTracks.plan(.applications([own]), ownBundleIdentifier: nil).map(\.appBundleID) == [own])
    }

    // A chosen bundle ID that starts with another chosen one and a dot (Chrome and Chrome Canary, Edge and its betas):
    // every process is in one track only, its longest chosen app's.

    /// The objects each track's tap takes of `processes`, by track id.
    private func taken(by plan: [SystemAudioTrackPlan], of processes: [AudioProcessInfo]) -> [String: [AudioObjectID]] {
        var taken: [String: [AudioObjectID]] = [:]
        for track in plan {
            let targets = SystemAudioSelection.targets(
                scope: track.scope, processes: processes, ownPID: 500, ownObjectID: 10, otherApplications: track.otherApplications)
            guard case .only(let objects) = targets else { Issue.record("\(track.trackID): \(targets)"); continue }
            taken[track.trackID] = objects
        }
        return taken
    }

    private func process(_ objectID: AudioObjectID, _ bundle: String) -> AudioProcessInfo {
        AudioProcessInfo(objectID: objectID, pid: pid_t(objectID) + 1000, bundleIdentifier: bundle, executablePath: nil, isPlayingAudio: true)
    }

    private var chromes: [AudioProcessInfo] {
        [
            AudioProcessInfo(objectID: 10, pid: 500, bundleIdentifier: own, executablePath: nil, isPlayingAudio: false),
            process(20, "com.google.Chrome"), process(21, "com.google.Chrome.helper"),
            process(22, "com.google.Chrome.canary"), process(23, "com.google.Chrome.canary.helper"),
            process(24, "com.apple.Safari"),
        ]
    }

    @Test func twoChosenPrefixesShareNoProcess() throws {
        // Canary's processes are Canary's only, Chrome keeps its helper.
        let plan = SystemAudioTracks.plan(.applications(["com.google.Chrome", "com.google.Chrome.canary"]), ownBundleIdentifier: own)
        #expect(taken(by: plan, of: chromes) == [
            "system-audio-com-google-Chrome": [20, 21], "system-audio-com-google-Chrome-canary": [22, 23],
        ])
        // In either order.
        let reversed = SystemAudioTracks.plan(.applications(["com.google.Chrome.canary", "com.google.Chrome"]), ownBundleIdentifier: own)
        #expect(taken(by: reversed, of: chromes) == [
            "system-audio-com-google-Chrome": [20, 21], "system-audio-com-google-Chrome-canary": [22, 23],
        ])
        // On macOS 26 the tap names Chrome's helper, never Canary's.
        let chrome = try #require(plan.first)
        let targets = SystemAudioSelection.targets(
            scope: chrome.scope, processes: chromes, ownPID: 500, ownObjectID: 10, otherApplications: chrome.otherApplications)
        #expect(SystemAudioSelection.tapBundleIDs(
            scope: chrome.scope, targets: targets, processes: chromes, ownPID: 500, ownBundleIdentifier: own)
            == ["com.google.Chrome", "com.google.Chrome.helper"])
        #expect(SystemAudioSelection.owner(of: "com.google.Chrome.canary.helper", among: ["com.google.Chrome", "com.google.Chrome.canary"])
            == "com.google.Chrome.canary")
        #expect(SystemAudioSelection.owner(of: "com.google.ChromeCanary", among: ["com.google.Chrome"]) == nil)
    }

    @Test func aHelperStaysWithItsApp() {
        // Chrome alone takes its helpers, Canary among them while Canary is not chosen, as in phase 2.
        let alone = SystemAudioTracks.plan(.applications(["com.google.Chrome", "com.apple.Safari"]), ownBundleIdentifier: own)
        #expect(taken(by: alone, of: chromes) == ["system-audio-com-google-Chrome": [20, 21, 22, 23], "system-audio-com-apple-Safari": [24]])
        // Canary chosen with Safari but not Chrome: Chrome and its helper are in no track.
        let canary = SystemAudioTracks.plan(.applications(["com.google.Chrome.canary", "com.apple.Safari"]), ownBundleIdentifier: own)
        #expect(taken(by: canary, of: chromes) == ["system-audio-com-google-Chrome-canary": [22, 23], "system-audio-com-apple-Safari": [24]])
        // One track of several apps (phase 2) takes each process once, whichever app it is of.
        #expect(SystemAudioSelection.targets(
            scope: .applications(["com.google.Chrome", "com.google.Chrome.canary"]), processes: chromes, ownPID: 500, ownObjectID: 10)
            == .only([20, 21, 22, 23]))
    }

    @Test func theSharedTrackLeavesTheOwnTracksTheirs() {
        let fillers = (1...6).map { "com.example.app\($0)" }
        // Chrome has its own track and Canary is in the shared one: Chrome's helper is not shared, Canary is.
        let chromeOwn = SystemAudioTracks.plan(
            .applications(fillers + ["com.google.Chrome", "com.example.app7", "com.google.Chrome.canary"]), ownBundleIdentifier: own)
        #expect(chromeOwn.count == 8 && chromeOwn.last?.trackID == "system-audio")
        let first = taken(by: chromeOwn, of: chromes)
        #expect(first["system-audio-com-google-Chrome"] == [20, 21])
        #expect(first["system-audio"] == [22, 23])
        // Canary has its own track and Chrome is shared: Canary's processes are not in the shared track.
        let canaryOwn = SystemAudioTracks.plan(
            .applications(fillers + ["com.google.Chrome.canary", "com.example.app7", "com.google.Chrome"]), ownBundleIdentifier: own)
        let second = taken(by: canaryOwn, of: chromes)
        #expect(second["system-audio-com-google-Chrome-canary"] == [22, 23])
        #expect(second["system-audio"] == [20, 21])
        // Every process in one track at most.
        for tracks in [first, second] {
            let all = tracks.values.flatMap { $0 }.filter { $0 != 10 }
            #expect(all.count == Set(all).count)
        }
    }

    @Test func aTrackRecordSaysItsApp() {
        let safari = ProcessTapSource(scope: .applications(["com.apple.Safari"]), trackID: "system-audio-com-apple-Safari", appName: "Safari")
        #expect(safari.trackID == "system-audio-com-apple-Safari" && safari.kind == .systemAudio)
        #expect(safari.sourceInfo == TrackSource(name: "Safari", includedBundleIDs: ["com.apple.Safari"]))
        #expect(SystemAudioTracks.trackRecord(of: safari) == TrackRecord(
            id: "system-audio-com-apple-Safari", kind: .systemAudio,
            source: TrackSource(name: "Safari", includedBundleIDs: ["com.apple.Safari"]), segments: [],
            appBundleID: "com.apple.Safari", appName: "Safari"))
        let synthetic = SyntheticAudioSource(
            trackID: "system-audio-com-spotify-client", kind: .systemAudio, channels: 2, app: (bundleID: "com.spotify.client", name: "Spotify"))
        #expect(synthetic.sourceInfo == TrackSource(name: "Spotify", includedBundleIDs: ["com.spotify.client"]))
        let record = SystemAudioTracks.trackRecord(of: synthetic)
        #expect(record.appBundleID == "com.spotify.client" && record.appName == "Spotify")

        // The microphone, system audio of every app, and the track of phase 2 or the shared one, none.
        let others: [any CaptureSource] = [
            SyntheticAudioSource(),
            ProcessTapSource(scope: .all),
            ProcessTapSource(scope: .applications(["com.apple.Safari"])),
            ProcessTapSource(scope: .applications(["com.apple.Safari", "com.apple.Music"]), trackID: "system-audio-x"),
            SyntheticAudioSource(trackID: "system-audio", kind: .systemAudio, channels: 2),
        ]
        for source in others {
            let record = SystemAudioTracks.trackRecord(of: source)
            #expect(record == TrackRecord(id: source.trackID, kind: source.kind, source: source.sourceInfo, segments: []))
            #expect(record.appBundleID == nil && record.appName == nil)
        }
        // Without a name the track is "System Audio", as before.
        #expect(ProcessTapSource(scope: .applications(["com.apple.Safari"]), trackID: "system-audio-com-apple-Safari").sourceInfo.name
            == "System Audio")
    }

    @Test func scopeOfATakeComesBack() {
        func take(_ tracks: [TrackRecord]) -> TakeRecord {
            TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: tracks)
        }
        let mic = TrackRecord(id: "mic", kind: .microphone, source: TrackSource(name: "Mic"), segments: [])
        func app(_ bundle: String) -> TrackRecord {
            TrackRecord(
                id: TrackRecord.systemAudioTrackID(bundleID: bundle, taken: []), kind: .systemAudio,
                source: TrackSource(name: bundle, includedBundleIDs: [bundle]), segments: [], appBundleID: bundle, appName: bundle)
        }
        // By app: the apps in the order of their tracks, the shared track's after them.
        let shared = TrackRecord(
            id: "system-audio", kind: .systemAudio, source: TrackSource(name: "System Audio", includedBundleIDs: ["com.c", "com.d"]),
            segments: [])
        #expect(SystemAudioTracks.scope(of: take([mic, app("com.b"), app("com.a")])) == .applications(["com.b", "com.a"]))
        #expect(SystemAudioTracks.scope(of: take([app("com.b"), mic, app("com.a"), shared])) == .applications(["com.b", "com.a", "com.c", "com.d"]))
        // Phase 2: its includedBundleIDs, or all of the system.
        #expect(SystemAudioTracks.scope(of: take([mic, shared])) == .applications(["com.c", "com.d"]))
        let all = TrackRecord(
            id: "system-audio", kind: .systemAudio, source: TrackSource(name: "System Audio", excludedBundleIDs: [own]), segments: [])
        #expect(SystemAudioTracks.scope(of: take([mic, all])) == .all)
        let silent = TrackRecord(
            id: "system-audio", kind: .systemAudio, source: TrackSource(name: "System Audio", includedBundleIDs: []), segments: [])
        #expect(SystemAudioTracks.scope(of: take([silent])) == .applications([]))
        // No system audio, none.
        #expect(SystemAudioTracks.scope(of: take([mic])) == nil)
        // And what a take records comes back as what records it again.
        let scope = SystemAudioScope.applications(["com.apple.Safari", "com.spotify.client"])
        let records = SystemAudioTracks.plan(scope, ownBundleIdentifier: own).map { plan in
            SystemAudioTracks.trackRecord(of: ProcessTapSource(scope: plan.scope, trackID: plan.trackID, appName: plan.appBundleID))
        }
        #expect(SystemAudioTracks.scope(of: take(records)) == scope)
    }
}
