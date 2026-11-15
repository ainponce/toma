// SPDX-License-Identifier: GPL-3.0-or-later
import CoreAudio
import CoreMedia
import Darwin
import Foundation
import ProjectFormat
import Testing

@testable import Recording

/// The system audio rules that need no tap: which processes a tap takes, what the manifest says it records, and
/// how a tap's buffers become samples. Recording real system audio is
/// `CaptureIntegrationTests.capturesSystemAudioForTwoSeconds`.
@Suite struct SystemAudioTests {
    private let own: pid_t = 500
    private let toma = AudioObjectID(10)

    private func process(_ objectID: AudioObjectID, pid: pid_t, bundle: String?, path: String?) -> AudioProcessInfo {
        AudioProcessInfo(objectID: objectID, pid: pid, bundleIdentifier: bundle, executablePath: path, isPlayingAudio: false)
    }

    private var tomaProcess: AudioProcessInfo {
        process(toma, pid: own, bundle: "dev.toma.Toma", path: "/Applications/Toma.app/Contents/MacOS/Toma")
    }

    // MARK: - Which processes

    @Test func allScopeExcludesOwnProcessAndNotificationSounds() {
        let (notif, sounds, usernoted, spotify, fake) = (AudioObjectID(11), AudioObjectID(12), AudioObjectID(13), AudioObjectID(14), AudioObjectID(15))
        let p = [
            tomaProcess,
            process(notif, pid: 601, bundle: "com.apple.notificationcenterui",
                    path: "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter"),
            process(sounds, pid: 602, bundle: "systemsoundserverd", path: "/usr/sbin/systemsoundserverd"),
            process(usernoted, pid: 603, bundle: nil, path: "/usr/sbin/usernoted"),
            process(spotify, pid: 604, bundle: "com.spotify.client", path: "/Applications/Spotify.app/Contents/MacOS/Spotify"),
            // Exact equality only: neither its bundle ID nor its path is one of the exclusions.
            process(fake, pid: 605, bundle: "com.example.systemsoundserverd.fake",
                    path: "/Applications/Fake.app/Contents/MacOS/systemsoundserverd"),
        ]
        #expect(SystemAudioSelection.targets(scope: .all, processes: p, ownPID: own, ownObjectID: toma)
            == .allExcept([toma, notif, sounds, usernoted]))
    }

    @Test func allScopeFindsItsOwnProcessByPIDWithoutAnObjectID() {
        let sounds = AudioObjectID(12)
        let p = [process(sounds, pid: 602, bundle: "com.apple.systemsoundserverd", path: nil), tomaProcess]
        #expect(SystemAudioSelection.targets(scope: .all, processes: p, ownPID: own, ownObjectID: nil) == .allExcept([toma, sounds]))
        #expect(SystemAudioSelection.targets(scope: .all, processes: [], ownPID: own, ownObjectID: nil) == .allExcept([]))
    }

    @Test func applicationScopeMatchesHelpersByBundlePrefix() {
        let (chrome, helper, canary) = (AudioObjectID(20), AudioObjectID(21), AudioObjectID(22))
        let p = [
            tomaProcess,
            process(chrome, pid: 700, bundle: "com.google.Chrome", path: nil),
            process(helper, pid: 701, bundle: "com.google.Chrome.helper", path: nil),
            process(canary, pid: 702, bundle: "com.google.ChromeCanary", path: nil),
        ]
        #expect(SystemAudioSelection.targets(scope: .applications(["com.google.Chrome"]), processes: p, ownPID: own, ownObjectID: toma)
            == .only([chrome, helper]))
    }

    @Test func applicationScopeTapsOnlyAPlaceholderWhenNoChosenAppRuns() {
        let p = [
            tomaProcess,
            process(11, pid: 601, bundle: "com.apple.notificationcenterui", path: nil),
            process(14, pid: 604, bundle: "com.spotify.client", path: nil),
        ]
        // Toma itself and the exclusions are never taken, even when chosen: nothing chosen runs.
        let scope = SystemAudioScope.applications(["dev.toma.Toma", "com.apple.notificationcenterui"])
        let placeholder = SystemAudioSelection.targets(scope: scope, processes: p, ownPID: own, ownObjectID: toma)
        #expect(placeholder == .only([toma]))
        #expect(SystemAudioSelection.isPlaceholder(placeholder, ownObjectID: toma))
        // Without an object of its own, the tap names nothing.
        let none = SystemAudioSelection.targets(scope: scope, processes: p, ownPID: own, ownObjectID: nil)
        #expect(none == .only([]))
        #expect(SystemAudioSelection.isPlaceholder(none, ownObjectID: nil))
    }

    @Test func onlyThePlaceholderRecordsSilence() {
        #expect(!SystemAudioSelection.isPlaceholder(.only([20, 21]), ownObjectID: toma))
        #expect(!SystemAudioSelection.isPlaceholder(.allExcept([toma]), ownObjectID: toma))
        #expect(!SystemAudioSelection.isPlaceholder(.allExcept([]), ownObjectID: nil))
        #expect(!SystemAudioSelection.isPlaceholder(.only([]), ownObjectID: toma))
    }

    /// Reads the real list, which needs no permission: asking connects this process to the audio system.
    @Test func catalogFindsThisProcessByPID() throws {
        let processes = try AudioProcessCatalog.processes()
        let mine = try #require(processes.first { $0.pid == getpid() })
        #expect(try AudioProcessCatalog.objectID(forPID: getpid()) == mine.objectID)
        #expect(mine.executablePath?.hasPrefix("/") == true)
        #expect(Set(processes.map(\.objectID)).count == processes.count)
        // A PID no process has.
        #expect(try AudioProcessCatalog.objectID(forPID: 99_999_999) == nil)
    }

    // MARK: - What the manifest says

    @Test func trackSourceNamesTheExcludedOrTheChosenApps() {
        #expect(SystemAudioSelection.trackSource(scope: .all, ownBundleIdentifier: "dev.toma.Toma")
            == TrackSource(name: "System Audio", excludedBundleIDs: ["dev.toma.Toma"] + SystemAudioExclusions.bundleIdentifiers))
        #expect(SystemAudioSelection.trackSource(scope: .all, ownBundleIdentifier: nil)
            == TrackSource(name: "System Audio", excludedBundleIDs: SystemAudioExclusions.bundleIdentifiers))
        let chosen = SystemAudioScope.applications(["com.google.Chrome", "dev.toma.Toma", "systemsoundserverd", "com.spotify.client"])
        #expect(SystemAudioSelection.trackSource(scope: chosen, ownBundleIdentifier: "dev.toma.Toma")
            == TrackSource(name: "System Audio", includedBundleIDs: ["com.google.Chrome", "com.spotify.client"]))
    }

    @Test func exclusionsAreTheNotificationAndAlertSounds() {
        #expect(SystemAudioExclusions.bundleIdentifiers
            == ["com.apple.notificationcenterui", "com.apple.UserNotificationCenter", "systemsoundserverd", "com.apple.systemsoundserverd"])
        #expect(SystemAudioExclusions.executablePaths == ["/usr/sbin/systemsoundserverd", "/usr/sbin/usernoted"])
    }

    @Test func tapSourceIsTheSystemAudioTrack() {
        let source = ProcessTapSource(scope: .applications(["com.google.Chrome"]))
        #expect(source.trackID == "system-audio" && source.kind == .systemAudio && source.media == .audio)
        #expect(source.activeDeviceUniqueID == nil)
        #expect(source.sourceInfo == TrackSource(name: "System Audio", includedBundleIDs: ["com.google.Chrome"]))
    }

    // MARK: - Buffers

    @Test(arguments: [false, true]) func tapBufferBecomesHostTimedSampleBuffer(planar: Bool) throws {
        let frames = 512
        let left = (0..<frames).map { Float($0) / 1024 }
        let right = (0..<frames).map { -Float($0) / 2048 }
        let format = stereoFloat(planar: planar)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        let memory = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { memory.deallocate() }
        if planar {
            for n in 0..<frames { (memory[n], memory[frames + n]) = (left[n], right[n]) }
            list.count = 2
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(memory))
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(memory + frames))
        } else {
            for n in 0..<frames { (memory[2 * n], memory[2 * n + 1]) = (left[n], right[n]) }
            list.count = 1
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: UnsafeMutableRawPointer(memory))
        }
        let host = mach_absolute_time()

        let sample = try TapSampleBuffers.make(from: list.unsafePointer, frameCount: UInt32(frames), format: format, hostTime: host)
        // A copy: the tap's buffers are only valid during its callback.
        memory.update(repeating: 0, count: frames * 2)

        #expect(sample.numSamples == frames)
        #expect(HostTime(sample.presentationTimeStamp) == HostTime(nanoseconds: AudioConvertHostTimeToNanos(host)))
        #expect(sample.duration == CMTime(value: CMTimeValue(frames), timescale: 48_000))
        let described = try #require(sample.formatDescription?.audioStreamBasicDescription)
        #expect(described.mFormatFlags == format.mFormatFlags && described.mChannelsPerFrame == 2)
        #expect(try channels(of: sample) == [left, right])
    }

    @Test(arguments: [false, true]) func placeholderBuffersAreSilence(planar: Bool) throws {
        let host = mach_absolute_time()
        let sample = try TapSampleBuffers.silence(frameCount: 256, format: stereoFloat(planar: planar), hostTime: host)
        #expect(sample.numSamples == 256)
        #expect(HostTime(sample.presentationTimeStamp) == HostTime(nanoseconds: AudioConvertHostTimeToNanos(host)))
        #expect(try channels(of: sample) == [[Float](repeating: 0, count: 256), [Float](repeating: 0, count: 256)])
    }

    private func stereoFloat(planar: Bool) -> AudioStreamBasicDescription {
        let bytesPerFrame: UInt32 = planar ? 4 : 8
        return AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
    }

    /// The Float32 samples of each channel of `sample`, interleaved or planar.
    private func channels(of sample: CMSampleBuffer) throws -> [[Float]] {
        let format = try #require(sample.formatDescription?.audioStreamBasicDescription)
        let count = Int(format.mChannelsPerFrame)
        let frames = sample.numSamples
        var result = [[Float]](repeating: [], count: count)
        try sample.withAudioBufferList { list, _ in
            if list.count == 1 {
                let data = try #require(list[0].mData).assumingMemoryBound(to: Float.self)
                for c in 0..<count { result[c] = (0..<frames).map { data[$0 * count + c] } }
            } else {
                for c in 0..<count {
                    let data = try #require(list[c].mData).assumingMemoryBound(to: Float.self)
                    result[c] = Array(UnsafeBufferPointer(start: data, count: frames))
                }
            }
        }
        return result
    }
}
