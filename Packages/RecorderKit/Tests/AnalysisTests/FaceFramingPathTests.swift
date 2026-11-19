// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing
@testable import Analysis

// "Follow the Face", `faceFraming-1` (phase 2 design §6.2, plan 2b decision 3), over the take of `ZoomFixtures` with its
// camera: one camera segment over the take's first 60 s, a 1280 × 720 frame, samples every 100 ms, the zoom of Follow the
// Face (1.4), and one clip over the first 20 s unless a test says otherwise, so output seconds are source seconds.

private typealias Z = ZoomFixtures

private let frame = SIMD2<Double>(1280, 720)
/// The width of the square shape's crop at 1.4×, in pixels of the frame: what the dead zone is 6 % of.
private let squareCrop = 720 / 1.4
private let cameraSegment = CameraSegment(take: Z.zoomTakeID, track: Z.cameraID, segment: 1)

/// A face of `size` (fractions of the frame) with its top left corner at `x`, `y`.
private func face(_ x: Double, _ y: Double, _ width: Double = 0.2, _ height: Double = 0.3) -> NormalizedRect {
    NormalizedRect(x: x, y: y, width: width, height: height)
}

/// The design's target of `rect`: its centre lifted 10 % of its height.
private func lifted(_ rect: NormalizedRect) -> SIMD2<Double> {
    SIMD2(rect.x + rect.width / 2, rect.y + rect.height / 2 - 0.1 * rect.height)
}

/// The camera's segment's face track: a sample every 100 ms of the camera from 0 to `seconds` (excluded), the face
/// `along(t)` at each.
private func faces(
    seconds: Double = 20, algorithm: String = CameraFaceTrack.id, frameSize: [Int] = [1280, 720],
    _ along: (Double) -> NormalizedRect?
) -> [CameraSegment: CameraFaceTrack] {
    let samples = (0..<Int((seconds * 10).rounded())).map { i in
        CameraFaceSample(t: Z.source(Double(i) / 10), face: along(Double(i) / 10))
    }
    return [cameraSegment: CameraFaceTrack(algorithm: algorithm, frameSize: frameSize, samples: samples)]
}

private func faceDocument(
    mode: CameraFramingMode = .face, zoom: Double = CameraFraming.faceZoom, sync: Int64 = 0,
    sequence: [Clip] = [Z.zoomClip(1, from: 0, to: 20)], show: Bool = true
) -> EditDocument {
    var document = Z.zoomDocument(sequence: sequence, bubble: .default)
    document.camera.show = show
    document.camera.framing = CameraFraming(mode: mode, center: NormalizedPoint(x: 0.3, y: 0.6), zoom: zoom)
    document.camera.syncOffset = sync
    return document
}

private func framing(
    _ faces: [CameraSegment: CameraFaceTrack], _ document: EditDocument = faceDocument()
) -> FaceFramingPath? {
    FaceFramingPath(
        document: document, take: Z.zoomTake(camera: true), timeMap: TimeMap(sequence: document.sequence), faces: faces)
}

private func bits(_ point: SIMD2<Double>) -> [UInt64] { [point.x.bitPattern, point.y.bitPattern] }

/// The first step on which the centre is not, bit for bit, what it was on step 0; `nil` if it never moves up to `last`.
private func firstMove(_ path: FaceFramingPath, through last: Int) -> Int? {
    let rest = bits(path.center(atStep: 0))
    let centers = path.centersSimulatedFromStart(through: last)
    return centers.firstIndex { bits($0) != rest }
}

@Test func targetIsTheFaceLiftedTenPercent() throws {
    let still = try #require(framing(faces { _ in face(0.4, 0.3) }))
    #expect(Z.near(still.center(atOutput: 0), SIMD2(0.5, 0.42), 1e-12))
    #expect(Z.near(still.center(atStep: Z.step(10)), SIMD2(0.5, 0.42), 1e-12))

    // From another face, the centre gets there.
    let moving = try #require(framing(faces { $0 < 1 ? face(0.1, 0.1) : face(0.4, 0.3) }))
    #expect(Z.near(moving.center(atOutput: 0), lifted(face(0.1, 0.1)), 1e-12))
    #expect(Z.near(moving.center(atOutput: Z.output(10)), SIMD2(0.5, 0.42), 1e-6))
}

@Test func smallMovesInsideTheDeadZoneAreIgnored() throws {
    let start = face(0.4, 0.3)
    /// The centre at 5 s with the face moved by `dx` and `dy` (fractions of the square crop's width) from 1 s on.
    func moved(_ dx: Double, _ dy: Double) throws -> (rest: SIMD2<Double>, at5: SIMD2<Double>) {
        let shifted = face(0.4 + dx * squareCrop / frame.x, 0.3 + dy * squareCrop / frame.y)
        let path = try #require(framing(faces { $0 < 1 ? start : shifted }))
        return (path.center(atStep: 0), path.center(atStep: Z.step(5)))
    }
    // 5 % across: ignored, bit for bit.
    let five = try moved(0.05, 0)
    #expect(bits(five.at5) == bits(five.rest))
    // 7 %: followed.
    let seven = try moved(0.07, 0)
    #expect(abs(seven.at5.x - (seven.rest.x + 0.07 * squareCrop / frame.x)) <= 1e-4)
    // 5 % down, in pixels of the frame: ignored; 7 % down, followed.
    #expect(bits(try moved(0, 0.05).at5) == bits(five.rest))
    #expect(try moved(0, 0.07).at5.y > five.rest.y + 0.06 * squareCrop / frame.y)
    // The distance is euclidean: 4 % on each axis is 5.7 % (ignored), 4.5 % on each is 6.4 % (followed).
    #expect(bits(try moved(0.04, 0.04).at5) == bits(five.rest))
    #expect(try moved(0.045, 0.045).at5.x > five.rest.x + 0.04 * squareCrop / frame.x)
}

@Test func theDeadZoneIsMeasuredFromTheTargetHeld() throws {
    // 4 % at 1 s (ignored) and 4 % more at 2 s: 8 % from the target held, followed from 2 s on.
    let step = 0.04 * squareCrop / frame.x
    let path = try #require(framing(faces { $0 < 1 ? face(0.4, 0.3) : $0 < 2 ? face(0.4 + step, 0.3) : face(0.4 + 2 * step, 0.3) }))
    #expect(firstMove(path, through: Z.step(5)) == Z.step(2))
    #expect(abs(path.center(atStep: Z.step(10)).x - (0.5 + 2 * step)) <= 1e-6)
}

@Test func springOfOnePointTwoSecondsCriticallyDamped() throws {
    let a = face(0.1, 0.2), b = face(0.6, 0.5)
    let path = try #require(framing(faces { $0 < 1 ? a : b }))
    let (from, to) = (lifted(a), lifted(b))
    let jump = Z.step(1)
    #expect(firstMove(path, through: Z.step(3)) == jump)
    let centers = path.centersSimulatedFromStart(through: Z.step(8))
    // Never past it, and on its way the whole time.
    for s in jump..<centers.count {
        #expect(centers[s].x <= to.x && centers[s].y <= to.y)
        #expect(centers[s].x >= centers[s - 1].x && centers[s].y >= centers[s - 1].y)
    }
    // 98 % of the way 1.2 s after the jump, as a critically damped spring of 1.2 s: 1 − e^(−2π) (1 + 2π) = 98.6 %.
    let done = (centers[jump + 720] - from) / (to - from)
    let continuous = 1 - exp(-2 * Double.pi) * (1 + 2 * Double.pi)
    #expect(done.x >= 0.98 && done.y >= 0.98)
    #expect(abs(done.x - continuous) <= 1e-3 && abs(done.y - continuous) <= 1e-3)
    #expect(Z.near(centers[Z.step(8)], to, 1e-6))
}

@Test func withoutAFaceItStays() throws {
    // 3 s without a face: the centre stays still where it was, bit for bit.
    let gone = try #require(framing(faces { $0 < 5 || $0 >= 8 ? face(0.4, 0.3) : nil }))
    #expect(firstMove(gone, through: Z.step(12)) == nil)
    // A face back inside the dead zone of where it stayed: still.
    let near = 0.03 * squareCrop / frame.x
    let back = try #require(framing(faces { $0 < 5 ? face(0.4, 0.3) : $0 < 8 ? nil : face(0.4 + near, 0.3) }))
    #expect(firstMove(back, through: Z.step(12)) == nil)
    // On its way somewhere when the face goes: it keeps going there (the target holds), not back nor to the middle.
    let a = face(0.1, 0.2), b = face(0.6, 0.5)
    let moving = try #require(framing(faces { $0 < 1 ? a : $0 < 1.5 ? b : nil }))
    #expect(Z.near(moving.center(atStep: Z.step(8)), lifted(b), 1e-6))
}

@Test func startsOnTheFirstFace() throws {
    let path = try #require(framing(faces { $0 < 2 ? nil : face(0.4, 0.3) }))
    #expect(Z.near(path.center(atOutput: 0), SIMD2(0.5, 0.42), 1e-12))
    #expect(firstMove(path, through: Z.step(6)) == nil)
    // Never a face in what the output shows but the first face's time: where it starts there too.
    let late = try #require(framing(faces { $0 < 15 ? nil : face(0.1, 0.2) }))
    #expect(Z.near(late.center(atOutput: 0), lifted(face(0.1, 0.2)), 1e-12))
}

@Test func readsTheCameraAtTheSyncOffset() throws {
    // The face moves at 3 s of the camera.
    let along: (Double) -> NormalizedRect? = { $0 < 3 ? face(0.1, 0.2) : face(0.6, 0.5) }
    let inTime = try #require(framing(faces(along)))
    #expect(firstMove(inTime, through: Z.step(5)) == Z.step(3))
    // 200 ms late: at output t the camera's frame of t − 200 ms, so the move is read at 3.2 s.
    let late = try #require(framing(faces(along), faceDocument(sync: 200_000_000)))
    #expect(firstMove(late, through: Z.step(5)) == Z.step(3.2))
    // 200 ms early, at 2.8 s.
    let early = try #require(framing(faces(along), faceDocument(sync: -200_000_000)))
    #expect(firstMove(early, through: Z.step(5)) == Z.step(2.8))
}

@Test func aCutReadsTheFaceAfterIt() throws {
    // The face moves at 5 s of the source; the output cuts from 4 s to 6 s, so it moves at 4 s of the output.
    let sequence = [Z.zoomClip(1, from: 0, to: 4), Z.zoomClip(2, from: 6, to: 20)]
    let path = try #require(framing(faces { $0 < 5 ? face(0.1, 0.2) : face(0.6, 0.5) }, faceDocument(sequence: sequence)))
    #expect(firstMove(path, through: Z.step(8)) == Z.step(4))
    // At twice the speed after the cut, the face of 6 s is read at 4 s, and one of 8 s at 5 s.
    let fast = [Z.zoomClip(1, from: 0, to: 4), Z.zoomClip(2, from: 6, to: 20, speed: 2)]
    let faster = try #require(framing(
        faces { $0 < 8 ? face(0.1, 0.2) : face(0.6, 0.5) }, faceDocument(sequence: fast)))
    #expect(firstMove(faster, through: Z.step(8)) == Z.step(5))
}

@Test func checkpointsGiveTheSameBits() throws {
    // A face that wanders, now and then lost, over cuts and speeds.
    var random = Z.ZoomRandom(seed: 0x00FA_CE00)
    var position = SIMD2<Double>(0.4, 0.3)
    var track: [Double: NormalizedRect?] = [:]
    for i in 0..<600 {
        position += SIMD2(Double.random(in: -0.04...0.04, using: &random), Double.random(in: -0.03...0.03, using: &random))
        position = position.clamped(lowerBound: SIMD2(0, 0), upperBound: SIMD2(0.8, 0.7))
        track[Double(i) / 10] = Double.random(in: 0...1, using: &random) < 0.1 ? nil : face(position.x, position.y)
    }
    let sequence = [Z.zoomClip(1, from: 0, to: 10), Z.zoomClip(2, from: 12, to: 25, speed: 2), Z.zoomClip(3, from: 30, to: 55, speed: 0.5)]
    let path = try #require(framing(faces(seconds: 60) { track[$0] ?? nil }, faceDocument(sequence: sequence)))
    let lastStep = StepGrid.firstStep(atOrAfter: TimeMap(sequence: sequence).duration)
    #expect(path.lastStep == lastStep)
    #expect(path.checkpoints.count == lastStep / StepGrid.checkpointEvery + 1)
    let fromStart = path.centersSimulatedFromStart(through: lastStep)
    var steps = (0..<1_000).map { _ in Int.random(in: 0...lastStep, using: &random) }
    steps += [0, 599, 600, 601, lastStep - 1, lastStep]
    for s in steps {
        #expect(bits(path.center(atStep: s)) == bits(fromStart[s]), "step \(s)")
    }
    // Held to the output's steps.
    #expect(bits(path.center(atStep: -5)) == bits(fromStart[0]))
    #expect(bits(path.center(atStep: lastStep + 900)) == bits(fromStart[lastStep]))
    // A frame of the output is on its step.
    for n in [0, 1, 59, 60, 61, 1_000, 3_989] {
        let τ = TimeMap.frameTime(n, frameRate: 60)
        #expect(bits(path.center(atOutput: τ)) == bits(fromStart[StepGrid.step(frame: n, frameRate: 60)]))
    }
}

@Test func betweenTwoStepsTheCenterIsMixed() throws {
    let path = try #require(framing(faces { $0 < 1 ? face(0.1, 0.2) : face(0.6, 0.5) }))
    let s = Z.step(1.5)
    let a = path.center(atStep: s), b = path.center(atStep: s + 1)
    // A third of the way from step s to the next (s is a multiple of 3: its time is a whole nanosecond).
    let τ = StepGrid.outputTime(ofStep: s) + 555_555
    let fraction = StepGrid.position(ofOutput: τ).fraction
    #expect(fraction > 0.3 && fraction < 0.4)
    #expect(Z.near(path.center(atOutput: τ), a + (b - a) * fraction, 1e-15))
}

@Test func onlyForFollowFace() {
    let some = faces { _ in face(0.4, 0.3) }
    #expect(framing(some) != nil)
    #expect(framing(some, faceDocument(mode: .center)) == nil)
    #expect(framing(some, faceDocument(mode: .manual)) == nil)
    // Follow the Face without any face: none in the caches, none in the samples, none of this camera's segment.
    #expect(framing([:]) == nil)
    #expect(framing(faces { _ in nil }) == nil)
    let other = CameraSegment(take: Z.zoomTakeID, track: Z.cameraID, segment: 2)
    #expect(framing([other: some[cameraSegment]!]) == nil)
    #expect(framing(faces(algorithm: "faceTrack-2") { _ in face(0.4, 0.3) }) == nil)
    #expect(framing(faces(frameSize: [1280]) { _ in face(0.4, 0.3) }) == nil)
    // A face that is not a number, or of no size, is none.
    #expect(framing(faces { _ in face(.nan, 0.3) }) == nil)
    #expect(framing(faces { _ in face(0.4, 0.3, 0, 0.3) }) == nil)
    // Nor with the camera hidden.
    #expect(framing(some, faceDocument(show: false)) == nil)
}

/// An hour of a face that moves all the time, sampled every 100 ms (36 000 samples), over 60 clips: the path is built
/// with each scene, so it must be quick. Run by an agent, with `TOMA_BENCH=1`, in release.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
func faceFramingOfAnHourIsQuick() throws {
    let hour = 3_600.0
    let samples = (0..<Int(hour * 10)).map { i -> CameraFaceSample in
        let t = Double(i) / 10
        let x = 0.4 + 0.25 * sin(0.37 * t) * cos(0.11 * t), y = 0.3 + 0.2 * sin(0.53 * t)
        return CameraFaceSample(t: Z.source(t), face: i % 97 == 0 ? nil : face(x, y))
    }
    let faces = [cameraSegment: CameraFaceTrack(algorithm: CameraFaceTrack.id, frameSize: [1920, 1080], samples: samples)]
    let sequence = (0..<60).map { k in Z.zoomClip(k + 1, from: Double(k) * 60, to: Double(k) * 60 + 59.5) }
    let document = faceDocument(sequence: sequence)
    let take = Z.zoomTake(camera: true, seconds: hour + 1)
    let timeMap = TimeMap(sequence: sequence)
    let build = { FaceFramingPath(document: document, take: take, timeMap: timeMap, faces: faces) }
    #expect(build() != nil)
    let clock = ContinuousClock()
    let times = (0..<5).map { _ in clock.measure { _ = build() } }.sorted()
    let median = times[2] / .milliseconds(1)
    print("faceFramingOfAnHourIsQuick: median of 5 \(String(format: "%.1f", median)) ms")
    #expect(median <= 30)
}
