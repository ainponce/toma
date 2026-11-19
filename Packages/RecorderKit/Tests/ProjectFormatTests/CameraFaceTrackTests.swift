// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing

// The face of a camera's segment, `faceTrack-1` (phase 2 design §6.2 and §10): the JSON of the analysis caches, and the
// fields of `AnalysisInputs` that carry it to the render.

private let face = NormalizedRect(x: 0.25, y: 0.5, width: 0.125, height: 0.25)

@Test func faceTrackJSONIsCanonical() throws {
    let track = CameraFaceTrack(
        algorithm: CameraFaceTrack.id, frameSize: [1280, 720],
        samples: [
            CameraFaceSample(t: HostTime(nanoseconds: 1_000_000_000), face: face),
            CameraFaceSample(t: HostTime(nanoseconds: 1_100_000_000), face: nil),
        ])
    let data = try ProjectJSON.encoder().encode(track)
    let expected = """
        {
          "algorithm" : "faceTrack-1",
          "frameSize" : [
            1280,
            720
          ],
          "samples" : [
            {
              "face" : {
                "height" : 0.25,
                "width" : 0.125,
                "x" : 0.25,
                "y" : 0.5
              },
              "t" : 1000000000
            },
            {
              "t" : 1100000000
            }
          ]
        }
        """
    #expect(String(decoding: data, as: UTF8.self) == expected)
    #expect(try ProjectJSON.decoder().decode(CameraFaceTrack.self, from: data) == track)
    // Written again, the same bytes.
    let again = try ProjectJSON.decoder().decode(CameraFaceTrack.self, from: data)
    #expect(try ProjectJSON.encoder().encode(again) == data)
}

@Test func aSampleWithoutAFaceNeverWritesNull() throws {
    let sample = CameraFaceSample(t: HostTime(nanoseconds: 7), face: nil)
    let text = String(decoding: try ProjectJSON.encoder().encode(sample), as: UTF8.self)
    #expect(!text.contains("null"))
    #expect(!text.contains("face"))
    let read = try ProjectJSON.decoder().decode(CameraFaceSample.self, from: Data(#"{"t": 7}"#.utf8))
    #expect(read == sample)
}

@Test func analysisInputsCarryNoFacesNorMasksByDefault() {
    #expect(AnalysisInputs.none.faceTracks.isEmpty)
    #expect(AnalysisInputs.none.personMasks.isEmpty)
    var inputs = AnalysisInputs()
    let segment = CameraSegment(take: "take-001", track: "camera-1", segment: 1)
    inputs.faceTracks[segment] = CameraFaceTrack(algorithm: CameraFaceTrack.id, frameSize: [1280, 720], samples: [])
    inputs.personMasks[segment] = URL(fileURLWithPath: "/tmp/seg-0001-personMask-1.mov")
    #expect(inputs != .none)
    #expect(inputs.faceTracks[CameraSegment(take: "take-001", track: "camera-1", segment: 2)] == nil)
    #expect(inputs.faceTracks[CameraSegment(take: "take-001", track: "camera-1", segment: 1)] != nil)
}
