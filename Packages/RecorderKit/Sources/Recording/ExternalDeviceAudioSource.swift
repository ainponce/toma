// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import ProjectFormat

/// Records the sound of an iPhone or iPad connected by cable (a `deviceAudio` track): the audio of the session its
/// screen's source records, in the device's own format, re-timed on the host clock. The session runs while either of
/// the two has a run; each one gets its own samples on its own queue. Its runs end, and come back, like the screen's.
public final class ExternalDeviceAudioSource: CaptureSource {
    public let trackID = "deviceAudio"
    public let kind = TrackKind.deviceAudio
    public let media = TrackMedia.audio
    private let runs: ExternalDeviceRuns

    /// The sound of the device `video` records, on its session.
    public init(video: ExternalDeviceCaptureSource) {
        runs = ExternalDeviceRuns(session: video.session, output: .audio, trackID: "deviceAudio")
    }

    /// The session this source and the screen's share.
    var session: ExternalDeviceSession { runs.session }

    public var activeDeviceUniqueID: String? { runs.activeDeviceUniqueID }

    /// The device's name and `uniqueID`; read like the screen's, never on the main thread.
    public var sourceInfo: TrackSource {
        TrackSource(name: (session.describe() ?? .unknown).name, deviceUniqueID: session.deviceUniqueID)
    }

    public func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        try await runs.start(on: queue, sink: sink)
    }

    public func stop() async {
        await runs.stop()
    }
}
