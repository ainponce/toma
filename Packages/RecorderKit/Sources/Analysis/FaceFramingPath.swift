// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Where Follow the Face frames the camera (phase 2 design §6.2, plan 2b decision 3), `faceFraming-1`: the centre of the
/// crop (`CameraFramingGeometry.crop`), in fractions of the camera's frame with y going down, simulated in output time
/// on the grid of 600 Hz of the motion paths (`StepGrid`).
///
/// - **The face it reads** on a step is the one of the camera's frame the output draws there: that of the take's camera
///   track (`CameraBubble`) at the source instant shown less `camera.syncOffset` (the frame of `t − syncOffset`, §5.9),
///   the face of the last sample at or before that instant in its segment's `faceTrack-1` (the biggest face, every
///   100 ms). There is none before a segment's first sample, between two segments, in a segment without its face track
///   (or of another algorithm, or with a frame that has no size), in a clip of another take, nor where the sample has
///   none.
/// - **The target** is the face's centre lifted `lift` (10 %) of its height. A face moves it only when it is at least
///   `deadZone` (6 %) of the width of the square shape's crop at the framing's zoom (`min(w, h) / zoom` pixels of the
///   frame, one dead zone for every layout) away from the target held, measured euclidean in pixels; then the target is
///   that face's. Without a face, for however long, it stays where it is.
/// - **The centre** follows the target with `spring` on each axis (critically damped, a response of 1.2 s,
///   `StepGrid.spring`), from rest on the target of the first face the output shows (on every step before it, the
///   centre is already there).
///
/// What a step reads is worked out once (`readings`): the face read changes at the output time at which the camera's
/// instant reaches a sample, a segment's start or end, or a clip's start; a step reads the last change at or before its
/// time. The whole state is kept every `StepGrid.checkpointEvery` steps, so a query simulates at most 600 steps from the
/// checkpoint before it, with the same bits as from output 0.
public struct FaceFramingPath: Sendable {
    public static let id = "faceFraming-1"
    /// How far above the face's centre the target is, in fractions of the face's height.
    public static let lift = 0.10
    /// The smallest move of the face that moves the target, in fractions of the width of the square shape's crop.
    public static let deadZone = 0.06
    /// The spring of the centre, on each axis.
    public static let spring = SpringSpec(damping: 1, response: 1.2)

    /// The last step simulated: the one of the end of the output.
    let lastStep: Int
    /// The framing's zoom (`CameraFramingGeometry.clampedZoom`): the dead zone's.
    private let zoom: Double
    /// What the steps read: in order of step, one per step at most, each different from the one before it.
    private let readings: [Reading]
    /// The target of the first face the output shows: where the centre starts, at rest.
    private let start: SIMD2<Double>
    /// The state on every `StepGrid.checkpointEvery`-th step from 0 to `lastStep`.
    private(set) var checkpoints: [State] = []

    /// `nil` unless the document's framing follows the face (`camera.framing.mode == .face`) and the output shows a face
    /// of the take's camera somewhere; also `nil` while the document hides the camera, as there is none to frame. The
    /// render then frames the middle of the picture, as Centred does at the same zoom.
    public init?(document: EditDocument, take: TakeRecord, timeMap: TimeMap, faces: [CameraSegment: CameraFaceTrack]) {
        guard document.camera.framing.mode == .face, !faces.isEmpty,
            let bubble = CameraBubble(document: document, take: take, timeMap: timeMap),
            let track = take.track(bubble.trackID)
        else { return nil }
        let entries = Self.entries(of: track, take: take.id, faces: faces)
        guard entries.contains(where: { $0.target != nil }) else { return nil }
        let readings = Self.readings(of: entries, document: document, take: take.id, timeMap: timeMap)
        guard let first = readings.lazy.compactMap(\.target).first else { return nil }
        self.readings = readings
        start = first
        zoom = CameraFramingGeometry.clampedZoom(document.camera.framing.zoom)
        lastStep = StepGrid.firstStep(atOrAfter: timeMap.duration)
        checkpoints = simulatedCheckpoints()
    }

    // MARK: - Queries

    /// The centre on step `s` of the grid (held to the steps of the output), from the checkpoint before it.
    public func center(atStep s: Int) -> SIMD2<Double> {
        let step = clamped(s)
        var run = run(toward: step)
        while run.step < step { advance(&run) }
        return run.state.center
    }

    /// The centre at output time `τ`: the one of its step when `τ` is on the grid (`StepGrid.position(ofOutput:)`, as
    /// every frame of the output is), otherwise the two around it mixed.
    public func center(atOutput τ: Int64) -> SIMD2<Double> {
        let (s, fraction) = StepGrid.position(ofOutput: τ)
        guard fraction > 0, s >= 0, s < lastStep else { return center(atStep: s) }
        var run = run(toward: s)
        while run.step < s { advance(&run) }
        let a = run.state.center
        advance(&run)
        return a + (run.state.center - a) * fraction
    }

    // MARK: - Internal (the simulation, for the tests)

    /// The centre, its velocity and the target it goes to, on a step.
    struct State: Sendable {
        var center: SIMD2<Double>
        var velocity: SIMD2<Double>
        var target: SIMD2<Double>
    }

    /// From `step` on, until the next reading, the face read: its target (`nil`, none) in a frame of `pixels`.
    struct Reading: Equatable, Sendable {
        var step: Int
        var target: SIMD2<Double>?
        var pixels: SIMD2<Double>
    }

    /// The centre on every step from 0 to `s` (held to `0...lastStep`), simulated from output 0 without the checkpoints:
    /// the one at index `n` is step `n`'s.
    func centersSimulatedFromStart(through s: Int) -> [SIMD2<Double>] {
        let last = clamped(s)
        var run = startingRun()
        var centers: [SIMD2<Double>] = []
        centers.reserveCapacity(last + 1)
        while run.step < last {
            advance(&run)
            centers.append(run.state.center)
        }
        return centers
    }

    // MARK: - Simulation

    /// One run of the simulation: its step, the state on it, and the first reading after it.
    private struct Run {
        var step: Int
        var state: State
        var next: Int
    }

    /// `s` held to `0...lastStep`.
    private func clamped(_ s: Int) -> Int {
        min(max(s, 0), lastStep)
    }

    /// A run at rest on `start` before step 0.
    private func startingRun() -> Run {
        Run(step: -1, state: State(center: start, velocity: .zero, target: start), next: 0)
    }

    /// A run from the checkpoint at or before step `s` (in `0...lastStep`).
    private func run(toward s: Int) -> Run {
        let index = s / StepGrid.checkpointEvery
        guard index < checkpoints.count else { return startingRun() }
        let step = index * StepGrid.checkpointEvery
        return Run(
            step: step, state: checkpoints[index], next: Self.partitionPoint(readings.count) { readings[$0].step <= step })
    }

    /// The state on every `StepGrid.checkpointEvery`-th step to `lastStep`, simulated from output 0.
    private func simulatedCheckpoints() -> [State] {
        var checkpoints: [State] = []
        checkpoints.reserveCapacity(lastStep / StepGrid.checkpointEvery + 1)
        var run = startingRun()
        while run.step < lastStep {
            advance(&run)
            if run.step % StepGrid.checkpointEvery == 0 { checkpoints.append(run.state) }
        }
        return checkpoints
    }

    /// Takes `run` to the next step: reads the face when it changes there, moves the target when the face is out of the
    /// dead zone around it, and moves the centre one step of 1/600 s toward the target.
    private func advance(_ run: inout Run) {
        run.step += 1
        if run.next < readings.count, readings[run.next].step <= run.step {
            let reading = readings[run.next]
            run.next += 1
            if let face = reading.target, moves(run.state.target, to: face, pixels: reading.pixels) {
                run.state.target = face
            }
        }
        StepGrid.spring(&run.state.center.x, &run.state.velocity.x, target: run.state.target.x, Self.spring)
        StepGrid.spring(&run.state.center.y, &run.state.velocity.y, target: run.state.target.y, Self.spring)
    }

    /// Whether a face whose target is `face` moves the target `held`, in a frame of `pixels`: whether they are at least
    /// `deadZone` of the square shape's crop at the zoom apart, in pixels.
    private func moves(_ held: SIMD2<Double>, to face: SIMD2<Double>, pixels: SIMD2<Double>) -> Bool {
        let apart = (face - held) * pixels
        let zone = Self.deadZone * min(pixels.x, pixels.y) / zoom
        return apart.x * apart.x + apart.y * apart.y >= zone * zone
    }

    // MARK: - What the steps read

    /// From camera instant `time` on (nanoseconds of the source), until the next entry, the face shown.
    private struct Entry {
        var time: UInt64
        var target: SIMD2<Double>?
        var pixels: SIMD2<Double>
    }

    /// The faces of `track`'s segments in camera time, in order: at each segment's start the face of its last sample at
    /// or before it (none without one), at each later sample of the segment its face, and none at its end (which is the
    /// next segment's start at the latest). A segment without its face track shows none.
    private static func entries(of track: TrackRecord, take: String, faces: [CameraSegment: CameraFaceTrack]) -> [Entry] {
        let segments = track.segments.sorted { $0.startHostTime < $1.startHostTime }
        var entries: [Entry] = []
        for (i, segment) in segments.enumerated() {
            let start = segment.startHostTime.nanoseconds
            let next = i + 1 < segments.count ? segments[i + 1].startHostTime.nanoseconds : .max
            let end = min(segment.endHostTime?.nanoseconds ?? .max, next)
            guard start < end else { continue }
            guard let faceTrack = faces[CameraSegment(take: take, track: track.id, segment: segment.index)],
                faceTrack.algorithm == CameraFaceTrack.id, let pixels = pixels(of: faceTrack.frameSize)
            else {
                entries.append(Entry(time: start, target: nil, pixels: .one))
                continue
            }
            var samples = faceTrack.samples
            if zip(samples, samples.dropFirst()).contains(where: { $0.t > $1.t }) { samples.sort { $0.t < $1.t } }
            var j = partitionPoint(samples.count) { samples[$0].t.nanoseconds <= start }
            entries.append(Entry(time: start, target: j > 0 ? target(of: samples[j - 1].face) : nil, pixels: pixels))
            while j < samples.count, samples[j].t.nanoseconds < end {
                entries.append(Entry(time: samples[j].t.nanoseconds, target: target(of: samples[j].face), pixels: pixels))
                j += 1
            }
            if end < .max { entries.append(Entry(time: end, target: nil, pixels: .one)) }
        }
        return entries
    }

    /// What the steps read, from `entries` over the clips of the sequence: at each clip's start the face shown at its
    /// first camera instant (none in a clip of another take), then each entry inside the clip at the output time of its
    /// source instant (its camera instant plus the sync offset). In order of step, the last of those on each step, and
    /// only where what is read changes.
    private static func readings(of entries: [Entry], document: EditDocument, take: String, timeMap: TimeMap) -> [Reading] {
        let offset = document.camera.syncOffset
        var readings: [Reading] = []
        func add(_ τ: Int64, _ entry: Entry?) {
            let target = entry?.target
            let reading = Reading(
                step: StepGrid.firstStep(atOrAfter: τ), target: target, pixels: target == nil ? .one : entry?.pixels ?? .one)
            // One per step, the last; a step reads it as it read the one before when they are the same (the dead zone
            // gives the same target from the same face).
            while let last = readings.last, last.step >= reading.step { readings.removeLast() }
            if let last = readings.last, last.target == reading.target, last.pixels == reading.pixels { return }
            readings.append(reading)
        }
        for (k, clip) in document.sequence.enumerated() where k < timeMap.clipOutputStarts.count {
            guard TimeMap.outputDuration(of: clip) > 0 else { continue }
            let clipStart = timeMap.clipOutputStarts[k]
            guard clip.take == take else {
                add(clipStart, nil)
                continue
            }
            let first = camera(ofSource: clip.start.nanoseconds, offset)
            let last = camera(ofSource: max(clip.end.nanoseconds, clip.start.nanoseconds), offset)
            var i = partitionPoint(entries.count) { entries[$0].time <= first }
            add(clipStart, i > 0 ? entries[i - 1] : nil)
            while i < entries.count, entries[i].time < last {
                let shown = HostTime(nanoseconds: Self.source(ofCamera: entries[i].time, offset))
                if let τ = timeMap.output(atSource: shown, take: take) { add(τ, entries[i]) }
                i += 1
            }
        }
        return readings
    }

    /// The target of `face`: its centre lifted `lift` of its height, held to the frame. `nil` without a face, and for one
    /// that is not a number or has no size.
    private static func target(of face: NormalizedRect?) -> SIMD2<Double>? {
        guard let face, face.x.isFinite, face.y.isFinite, face.width.isFinite, face.height.isFinite, face.width > 0,
            face.height > 0
        else { return nil }
        let x = face.x + face.width / 2, y = face.y + face.height / 2 - lift * face.height
        return SIMD2(min(max(x, 0), 1), min(max(y, 0), 1))
    }

    /// A frame's width and height in pixels, when there are two and both are above 0.
    private static func pixels(of frameSize: [Int]) -> SIMD2<Double>? {
        guard frameSize.count == 2, frameSize[0] > 0, frameSize[1] > 0 else { return nil }
        return SIMD2(Double(frameSize[0]), Double(frameSize[1]))
    }

    /// The camera instant drawn where the output shows source instant `source`: `source − offset`, held to the ends of
    /// the clock.
    private static func camera(ofSource source: UInt64, _ offset: Int64) -> UInt64 {
        if offset >= 0 { return source >= offset.magnitude ? source - offset.magnitude : 0 }
        let (sum, overflow) = source.addingReportingOverflow(offset.magnitude)
        return overflow ? .max : sum
    }

    /// The source instant at which the output draws camera instant `camera`: `camera + offset`, held to the ends of the
    /// clock.
    private static func source(ofCamera camera: UInt64, _ offset: Int64) -> UInt64 {
        if offset < 0 { return camera >= offset.magnitude ? camera - offset.magnitude : 0 }
        let (sum, overflow) = camera.addingReportingOverflow(offset.magnitude)
        return overflow ? .max : sum
    }

    /// The first index in `0..<count` for which `isBefore` is false, given that it is true for a prefix and false after.
    private static func partitionPoint(_ count: Int, _ isBefore: (Int) -> Bool) -> Int {
        var (low, high) = (0, count)
        while low < high {
            let middle = low + (high - low) / 2
            if isBefore(middle) { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
