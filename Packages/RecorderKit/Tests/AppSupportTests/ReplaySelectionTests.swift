// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import Testing

// What the Replay records (fases 4 y 5 design §10.4, plan 5c decision 10): the sources of the last recording, its window
// or iPhone as a display, and only what is allowed already.

@Suite struct ReplaySelectionTests {
    /// Display 1 is the main one; display 2 is to its right.
    private static let displays = [
        DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isMain: true, maximumFramesPerSecond: 120),
        DisplayInfo(id: 2, frame: Rect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1, isMain: false, maximumFramesPerSecond: 60),
    ]
    private static let everything: Set<PermissionKind> = [.screenRecording, .microphone, .camera, .systemAudio]

    private static func make(_ last: CaptureSelection?, granted: Set<PermissionKind> = everything) -> CaptureSelection {
        ReplaySelection.make(last: last, displays: displays, windowDisplay: { $0 == 4242 ? 2 : nil }, granted: granted)
    }

    @Test func displaysAreKept() {
        let last = CaptureSelection(
            mode: .display, displayIDs: [2, 1], camera: .device(uniqueID: "cam"), microphone: .systemDefault,
            systemAudio: .applications(["com.apple.Music"]))
        #expect(Self.make(last) == last)
    }

    @Test func missingDisplayBecomesTheMain() {
        let last = CaptureSelection(mode: .display, displayIDs: [2, 7], camera: .off, microphone: .systemDefault, systemAudio: .off)
        #expect(Self.make(last).displayIDs == [2, 1])
        // Twice the main is the main once.
        let gone = CaptureSelection(mode: .display, displayIDs: [7, 1, 8], camera: .off, microphone: .off, systemAudio: .off)
        #expect(Self.make(gone) == CaptureSelection(mode: .display, displayIDs: [1], camera: .off, microphone: .off, systemAudio: .off))
        // An area of a display that is gone is the main display, whole.
        let area = CaptureSelection(
            mode: .area, displayIDs: [7], area: AreaChoice(displayID: 7, rect: Rect(x: 0, y: 0, width: 400, height: 300)),
            camera: .off, microphone: .systemDefault, systemAudio: .off)
        #expect(Self.make(area) == CaptureSelection(mode: .display, displayIDs: [1], camera: .off, microphone: .systemDefault, systemAudio: .off))
    }

    @Test func areaIsKept() {
        let last = CaptureSelection(
            mode: .area, displayIDs: [2], area: AreaChoice(displayID: 2, rect: Rect(x: 1600, y: 100, width: 640, height: 360)),
            camera: .systemDefault, microphone: .systemDefault, systemAudio: .all)
        #expect(Self.make(last) == last)
    }

    @Test func windowBecomesItsDisplay() {
        let last = CaptureSelection(
            mode: .window, displayIDs: [1], windowID: 4242, windowOwner: WindowOwner(bundleID: "com.apple.Safari", name: "Safari"),
            camera: .off, microphone: .systemDefault, systemAudio: .all)
        #expect(Self.make(last) == CaptureSelection(mode: .display, displayIDs: [2], camera: .off, microphone: .systemDefault, systemAudio: .all))
    }

    @Test func goneWindowBecomesTheMain() {
        let gone = CaptureSelection(mode: .window, displayIDs: [], windowID: 99, camera: .off, microphone: .off, systemAudio: .off)
        #expect(Self.make(gone) == CaptureSelection(mode: .display, displayIDs: [1], camera: .off, microphone: .off, systemAudio: .off))
        // Its display is no longer connected, or no window was chosen at all.
        let elsewhere = ReplaySelection.make(last: gone, displays: Self.displays, windowDisplay: { _ in 7 }, granted: Self.everything)
        #expect(elsewhere.displayIDs == [1] && elsewhere.mode == .display)
        let none = CaptureSelection(mode: .window, displayIDs: [], camera: .off, microphone: .off, systemAudio: .off)
        #expect(Self.make(none).displayIDs == [1])
    }

    @Test func iPhoneBecomesTheMain() {
        let last = CaptureSelection(
            mode: .device, displayIDs: [], camera: .systemDefault, microphone: .systemDefault, systemAudio: .off,
            deviceUniqueID: "00008110-000A")
        #expect(Self.make(last) == CaptureSelection(
            mode: .display, displayIDs: [1], camera: .systemDefault, microphone: .systemDefault, systemAudio: .off))
    }

    @Test func noLastRecordingIsTheMainAlone() {
        let main = CaptureSelection(mode: .display, displayIDs: [1], camera: .off, microphone: .off, systemAudio: .off)
        #expect(Self.make(nil) == main)
        // The main display is the one with the menu bar, wherever it is in the list.
        let reversed = ReplaySelection.make(
            last: nil, displays: Self.displays.reversed(), windowDisplay: { _ in nil }, granted: Self.everything)
        #expect(reversed == main)
    }

    @Test func ungrantedMicCameraAndSystemAudioAreLeftOut() {
        let last = CaptureSelection(
            mode: .display, displayIDs: [1], camera: .systemDefault, microphone: .device(uniqueID: "mic"), systemAudio: .all)
        let screenOnly = Self.make(last, granted: [.screenRecording])
        #expect(screenOnly == CaptureSelection(mode: .display, displayIDs: [1], camera: .off, microphone: .off, systemAudio: .off))
        let withMicrophone = Self.make(last, granted: [.screenRecording, .microphone])
        #expect(withMicrophone.microphone == .device(uniqueID: "mic") && withMicrophone.camera == .off && withMicrophone.systemAudio == .off)
        let withCameraAndSound = Self.make(last, granted: [.screenRecording, .camera, .systemAudio])
        #expect(withCameraAndSound.camera == .systemDefault && withCameraAndSound.systemAudio == .all && withCameraAndSound.microphone == .off)
    }
}
