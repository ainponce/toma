// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import SyntheticCapture
import Testing

@testable import Recording

@Suite struct DiskFullClassificationTests {
    @Test func outOfSpaceShapes() {
        #expect(isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        #expect(isOutOfSpace(POSIXError(.ENOSPC)))
        #expect(isOutOfSpace(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue)))
        #expect(isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        // -11807 is AVError.diskFull: recognized as it is, and through a chain that ends in POSIX 28.
        let chained = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12_345, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28),
            ]),
        ])
        #expect(isOutOfSpace(chained))
        let multiple = NSError(domain: "Something", code: 1, userInfo: [
            NSMultipleUnderlyingErrorsKey: [NSError(domain: "Other", code: 2), NSError(domain: AVFoundationErrorDomain, code: -11807)],
        ])
        #expect(isOutOfSpace(multiple))
        #expect(!isOutOfSpace(NSError(domain: AVFoundationErrorDomain, code: -11800)))
        #expect(!isOutOfSpace(NSError(domain: "TestWriter", code: 7)))
    }

    /// A writer that fails with a bare -11800, which AVFoundation also reports a full disk with. With the
    /// volume nearly full, the segment ends `diskFull` and the track stops writing; with room, it is an
    /// ordinary writer failure and the next sample opens a new segment.
    @Test(arguments: [(Int64(1_000_000), true), (Int64(10_000_000_000), false)])
    func unrecognizedWriterFailureOnANearlyFullVolumeIsDiskFull(freeBytes: Int64, full: Bool) async throws {
        try await withTemporaryDirectory { directory in
            let package = try ProjectPackage.create(in: directory, name: "Test", app: AppInfo(name: "Tests", version: "0"), now: Date())
            let source = SyntheticVideoSource(width: 320, height: 180, framesPerSecond: 30)
            let takeID = "take-001"
            try FileManager.default.createDirectory(
                at: package.trackDirectory(take: takeID, track: source.trackID), withIntermediateDirectories: true)
            let store = try ManifestStore(package: package)
            try store.update {
                $0.takes.append(TakeRecord(id: takeID, status: .recording, startedAt: Date(), tracks: [
                    TrackRecord(id: source.trackID, kind: source.kind, source: source.sourceInfo, segments: []),
                ]))
            }
            let log = try EventLogWriter(url: package.eventsURL(take: takeID))
            defer { try? log.close() }
            let (warnings, warningsContinuation) = AsyncStream.makeStream(of: RecordingWarning.self)
            let made = Mutex(0)
            let diskFullCalls = Mutex(0)
            let failure = NSError(domain: AVFoundationErrorDomain, code: -11800)
            let context = PipelineContext(
                package: package, takeID: takeID, store: store, log: log, warnings: warningsContinuation,
                configuration: RecordingConfiguration(), writerFactory: { url, media in
                    let inner = try FragmentedTrackWriter(url: url, media: media)
                    let first = made.withLock { count in
                        count += 1
                        return count == 1
                    }
                    // A few frames, so the segment has started, then the failure.
                    return first ? ScriptedWriter(inner: inner, failAfterAppends: 3, failure: failure) : inner
                },
                clock: HostTime.now, ticks: .live, onDiskFull: { diskFullCalls.withLock { $0 += 1 } }, freeBytes: { freeBytes })
            let pipeline = TrackPipeline(source: source, context: context, isSoleScreen: true)
            try await pipeline.start()
            // Until the failure was handled: the take told about the full disk, or a new segment started.
            let handled = await eventually(timeout: .seconds(30)) {
                full ? diskFullCalls.withLock { $0 } >= 1 : store.manifest.takes.first?.tracks.first?.segments.count == 2
            }
            #expect(handled)
            // A full disk opens no segment however long the track goes on.
            try await Task.sleep(for: .milliseconds(300))
            #expect(await pipeline.close(reason: .stopped, at: HostTime.now()).isEmpty)
            warningsContinuation.finish()

            let segments = try #require(store.manifest.takes.first?.tracks.first?.segments)
            if full {
                #expect(segments.map(\.endReason) == [.diskFull])
                #expect(diskFullCalls.withLock { $0 } >= 1)
                #expect(made.withLock { $0 } == 1, "a new segment was opened on the full disk")
            } else {
                #expect(segments.map(\.endReason) == [.writerError(domain: AVFoundationErrorDomain, code: -11800), .stopped])
                #expect(diskFullCalls.withLock { $0 } == 0)
                #expect(made.withLock { $0 } == 2)
            }
            var received: [RecordingWarning] = []
            for await warning in warnings { received.append(warning) }
            #expect(received == [.writerFailed(track: source.trackID)])
        }
    }
}
