// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import SyntheticCapture
import Testing

@testable import Recording

// The coordinator raises a package to version 4 only when a take uses what only 4 defines: before the record of a take
// with a device's track, and before the first `keyPress` line (through `FormatRaising`). A take with the keys on and
// no key pressed stays at 3, which the app of phase 1 opens.

extension RealTimeRecordingTests {
    @Suite struct RecordingFormat4Tests {
        /// A key recorder whose keys a manual tick types, one a tick, never under secure input; inside a composite, as
        /// the app has it.
        private struct Keys {
            static let every: Duration = .milliseconds(50)
            let ticks = ManualTicks()
            let recorder: KeyPressRecorder
            let input: CompositeInputRecorder

            init(text: String) {
                recorder = KeyPressRecorder(
                    source: ScriptedKeyEvents(text: text, every: Self.every, ticks: ticks.ticks), secureInput: { false })
                input = CompositeInputRecorder([NoInputRecorder(), recorder])
            }

            func type() async {
                await ticks.fire(every: Self.every)
            }
        }

        @Test func aTakeWithKeysOnButNoKeyStaysAt3() async throws {
            try await withTemporaryDirectory { directory in
                let keys = Keys(text: "a")
                let rig = try Rig(in: directory, input: keys.input)
                let id = try await rig.coordinator.start()
                #expect(keys.recorder.isListening)
                try await Task.sleep(for: .milliseconds(600))
                _ = try await rig.coordinator.stop()
                let manifest = try rig.manifestOnDisk()
                #expect(manifest.formatVersion == 3)
                #expect(try rig.takeOnDisk(id).status == .complete)
                #expect(!(try rig.events(id).contains { $0.kind.requiresFormatVersion4 }))
                #expect(!keys.recorder.isListening)
            }
        }

        @Test func aTakeWithAKeyIsAt4() async throws {
            try await withTemporaryDirectory { directory in
                let keys = Keys(text: "a")
                let rig = try Rig(in: directory, input: keys.input)
                let id = try await rig.coordinator.start()
                #expect(try rig.manifestOnDisk().formatVersion == 3)
                await keys.type()
                // Raised on disk as the key is written, before the take ends.
                #expect(try rig.manifestOnDisk().formatVersion == 4)
                try await Task.sleep(for: .milliseconds(400))
                _ = try await rig.coordinator.stop()
                let manifest = try rig.manifestOnDisk()
                #expect(manifest.formatVersion == 4)
                // The tracks do not need 4: the line does.
                #expect(!manifest.needsFormatVersion4)
                #expect(try rig.takeOnDisk(id).status == .complete)
                let lines = try rig.events(id).filter(\.kind.requiresFormatVersion4)
                #expect(lines.map(\.kind) == [.keyPress(code: 0, chars: "a", mods: 0, isRepeat: false)])
            }
        }

        @Test func aDeviceTakeIsAt4BeforeItsRecord() async throws {
            try await withTemporaryDirectory { directory in
                let device = SyntheticVideoSource(trackID: "device", kind: .device, width: 390, height: 844, framesPerSecond: 30)
                let rig = try Rig(in: directory, sources: [device, SyntheticAudioSource()])
                #expect(try rig.manifestOnDisk().formatVersion == 3)
                // The store refuses a device's track in a package of 3: the take starts only if 4 came first.
                let id = try await rig.coordinator.start()
                let live = try rig.manifestOnDisk()
                #expect(live.formatVersion == 4)
                #expect(live.takes.first { $0.id == id }?.tracks.map(\.kind) == [.device, .microphone])
                try await Task.sleep(for: .milliseconds(600))
                _ = try await rig.coordinator.stop()
                let manifest = try rig.manifestOnDisk()
                #expect(manifest.formatVersion == 4)
                let take = try rig.takeOnDisk(id)
                #expect(take.status == .complete)
                #expect(take.track("device")?.segments.map(\.endReason) == [.stopped])
                await rig.warningsDone.value
                #expect(rig.warnings.all.isEmpty)
            }
        }
    }
}
