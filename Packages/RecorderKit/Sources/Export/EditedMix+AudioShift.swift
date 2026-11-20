// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Where the sound of each clip of a sequence starts in the mix, in output frames at 48 kHz, and how far from the
/// clip's own start its source is read there (phase 3 design §7.3 and §13, step 1: the cut of the sound moved, a J or an
/// L cut; plan 3c decision 10): `EditedMix` plays clip `k` from output frame `starts[k]` to `starts[k + 1]` (the last one
/// to the end of the content, `end`), from the frame of its take at its start moved by `sourceShift[k]`.
///
/// - The cut at the start of clip `k` moves its sound by `δ_k` ns of output: its `Clip.audioShift` held to
///   `SequenceRules.audioShiftRange(of:at:takeBounds:)`, so to half of the shorter clip at its edge (none at the first
///   clip, at a clip with content and at the one after it) and to what each take has (`takeBounds`, each take's
///   `TakeTimeline.editableBounds` in the mix, which the commands hold it to as well): a J cut (negative) never has clip `k`
///   heard from before the start of its take, an L cut (positive) never has clip `k − 1` heard past the end of its own.
///   A take without bounds there is held to the clips alone. The commands that write the sequence hold every cut to the
///   same bounds (`SequenceChanges`), so a document they write sounds where `TimeMap.audioStarts` puts it.
/// - `starts[k] = frames(O_k + δ_k)` and `sourceShift[k] = frames(round(δ_k × v_k))` (`EditedMix.frames(ofNanoseconds:)`,
///   `v_k` by `ClipSpeed.clamped`): a J cut has clip `k` heard sooner from its source before `s_k`, an L cut has the clip
///   before heard on from its source past `e_{k−1}` (at another speed, its stretch fed it, `heardEnd(ofClip:)`), and the
///   fade of 192 frames between them is at `starts[k]`, where the sound cuts. The picture keeps to `O_k`.
/// - Without a cut moved (every `audioShift` 0, the documents of phases 1 and 2), `starts` are the clips' own starts
///   (`TimeMap.clipOutputStarts`) and every `sourceShift` is 0: the mix plays what phase 2 played.
struct AudioCuts: Sendable {
    /// The output frame where the sound of each clip starts, in the order of the sequence.
    let starts: [Int64]
    /// How many frames of its take's timeline before (negative) or after its start the sound of each clip is read from
    /// where it starts, in the order of the sequence.
    let sourceShift: [Int64]
    /// The output frame where the content ends, and the sound of the last clip with it: `frames(D)`.
    let end: Int64
    /// `δ_k`, the cut of the sound at the start of each clip as the mix reads it, in ns of output.
    let shifts: [Int64]
    /// `O_k + δ_k`, where the sound of each clip starts in ns of output, saturating.
    private let soundStarts: [Int64]
    /// The sequence's map, whose `audioSource(ofClip:atOutput:)` gives the source each clip is heard at.
    private let timeMap: TimeMap

    /// The cuts of the sound of `document`'s sequence, whose map is `timeMap`, held to the clips at each edge and to
    /// `takeBounds` (each take's source the sound can be read in, by take ID: the mix's `EditedMix.takeBounds`, which the
    /// commands that write the sequence hold it to too), as `SequenceRules.audioShift(of:at:takeBounds:)` holds it.
    /// - Precondition: `timeMap` is the map of `document.sequence`.
    init(document: EditDocument, timeMap: TimeMap, takeBounds: [String: ClosedRange<HostTime>]) {
        let sequence = document.sequence
        precondition(timeMap.clipOutputStarts.count == sequence.count, "AudioCuts: a map of another sequence")
        let shifts = sequence.indices.map { k in SequenceRules.audioShift(of: sequence, at: k, takeBounds: takeBounds) }
        let soundStarts = sequence.indices.map { k -> Int64 in
            let (sum, overflow) = timeMap.clipOutputStarts[k].addingReportingOverflow(shifts[k])
            return overflow ? (shifts[k] < 0 ? .min : .max) : sum
        }
        self.shifts = shifts
        self.soundStarts = soundStarts
        starts = soundStarts.map(EditedMix.frames(ofNanoseconds:))
        sourceShift = sequence.indices.map { k -> Int64 in
            guard shifts[k] != 0 else { return 0 }
            // Within half a clip of output, at most 16×: never out of `Int64`.
            let source = (Double(shifts[k]) * ClipSpeed.clamped(sequence[k].speed)).rounded()
            return EditedMix.frames(ofNanoseconds: Int64(source))
        }
        end = EditedMix.frames(ofNanoseconds: timeMap.duration)
        self.timeMap = timeMap
    }

    /// The output frames where the sound of clip `k` plays: `starts[k] ..< starts[k + 1]` (`end` for the last clip),
    /// empty for a clip whose sound lasts no frame.
    func window(ofClip k: Int) -> Range<Int64> {
        let upper = k + 1 < starts.count ? starts[k + 1] : end
        return starts[k]..<max(starts[k], upper)
    }

    /// The clip whose sound plays output frame `frame` (`window(ofClip:)`), with content or not; `nil` outside
    /// `0 ..< end`.
    func clip(atOutputFrame frame: Int64) -> Int? {
        guard frame >= 0, frame < end, !starts.isEmpty else { return nil }
        // The last clip whose sound starts at or before the frame: its window holds it, the starts being in order.
        var (low, high) = (0, starts.count)
        while low < high {
            let middle = low + (high - low) / 2
            if starts[middle] <= frame { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? low - 1 : nil
    }

    /// The source instant of the take of clip `k` heard at output frame `frame`, in signed nanoseconds of host time:
    /// `TimeMap.audioSource(ofClip:atOutput:)` at the frame's output time, `round(frame × 10⁹ / 48 000)` ns, through
    /// the clip's own mapping, so before and after the clip too (a J and an L cut).
    /// - Precondition: `k` is a clip of the sequence.
    func sourceNanoseconds(ofClip k: Int, atOutputFrame frame: Int64) -> Int64 {
        timeMap.audioSource(ofClip: k, atOutput: Self.nanoseconds(ofFrame: frame))
    }

    /// Where the sound of clip `k` stops in its take's source, in signed nanoseconds of host time, when an L cut at the
    /// clip after it has it heard past its own end: the source it is heard at where that clip's sound starts,
    /// `TimeMap.audioSource(ofClip:atOutput:)` at `O_{k+1} + δ_{k+1}`; `nil` without one.
    func heardEnd(ofClip k: Int) -> Int64? {
        guard k + 1 < shifts.count, shifts[k + 1] > 0 else { return nil }
        return timeMap.audioSource(ofClip: k, atOutput: soundStarts[k + 1])
    }

    /// `round(frame × 10⁹ / 48 000)`, in integers (never a half: 10⁹ / 48 000 = 62 500 / 3), saturating.
    static func nanoseconds(ofFrame frame: Int64) -> Int64 {
        let (whole, part) = frame.quotientAndRemainder(dividingBy: 3)
        let (scaled, overflow) = whole.multipliedReportingOverflow(by: 62_500)
        if overflow { return frame < 0 ? .min : .max }
        // `part × 62 500 / 3` rounded, `part` from −2 to 2: its remainder is never 0 but at 0.
        let rest = part >= 0 ? (part * 62_500 + 1) / 3 : -((-part * 62_500 + 1) / 3)
        let (sum, sumOverflow) = scaled.addingReportingOverflow(rest)
        return sumOverflow ? (frame < 0 ? .min : .max) : sum
    }
}
