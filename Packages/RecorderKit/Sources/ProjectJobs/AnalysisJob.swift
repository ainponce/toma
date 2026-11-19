// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Synchronization

/// One piece of phase 2's analysis of a project (design of phase 2, §10): what it is about, which also tells it apart
/// from every other job of the project's queue. Two requests for the same kind are one job.
public enum AnalysisJobKind: Hashable, Sendable {
    /// The words of an audio track of a take, into the document (`speechTranscriber-1`).
    case transcription(take: String, track: String)
    /// The person mask of a segment of the camera (`personMask-1`).
    case personMask(take: String, track: String, segment: Int)
    /// The face track of a segment of the camera (`faceTrack-1`).
    case faceTrack(take: String, track: String, segment: Int)
    /// The microphone's sound without noise, for a segment (`soundIsolation-1`).
    case soundIsolation(take: String, track: String, segment: Int)
    /// The loudness of an audio track (`loudness-1`).
    case loudness(take: String, track: String)
    /// The search for sensitive data on the screen of a take (`sensitiveScan-1`).
    case sensitiveScan(take: String)
}

/// Why a job did not make what it was asked for; the app says it in words. Cases are only ever added, at the end.
public enum JobProblem: Equatable, Sendable {
    /// What it needs comes with macOS 26 (`SpeechTranscriber`).
    case needsMacOS26
    /// The system's model for `locale` (BCP 47) is not on this Mac.
    case modelNotInstalled(locale: String)
    /// This Mac cannot do it (no Neural Engine, no Audio Unit).
    case notOnThisMac
    /// A source file (relative to the package) could not be read.
    case sourceUnreadable(file: String)
    /// The drive is full.
    case noSpace
    /// Anything else, described.
    case failed(String)
}

/// Where a job is.
public enum JobState: Equatable, Sendable {
    /// In the queue.
    case waiting
    /// Its work runs; `progress` from 0 to 1, which never goes down.
    case running(progress: Double)
    /// It made what it was asked for.
    case done
    /// It could not, for `JobProblem`: asking again may work.
    case failed(JobProblem)
    /// It cannot on this Mac as it is now, for `JobProblem` (macOS 15, a model not installed).
    case unavailable(JobProblem)
}

/// What a job made.
public enum JobOutput: Equatable, Sendable {
    /// A file of the project's caches (`ProjectCaches.analysisFile`, `ProjectCaches.scanFile`).
    case cached(URL)
    /// The words, for the document.
    case transcript(Transcript)
}

/// What a job's work throws to say why it made nothing: the job ends `failed(problem)`, or `unavailable(problem)`
/// when `unavailable`, and whoever waits for it gets this error. Anything else a work throws ends it
/// `failed(.failed(String(describing: error)))`, and its waiters get that as a `JobError`.
public struct JobError: Error, Equatable {
    public var problem: JobProblem
    public var unavailable: Bool

    public init(_ problem: JobProblem, unavailable: Bool = false) {
        self.problem = problem
        self.unavailable = unavailable
    }
}

/// How a job's work says how far along it is. Any thread may call it, as often as it likes: the fraction is clamped
/// to 0…1 (`nan` is ignored), never goes down, and reaches the job's state only once it is at least 1 % past the last
/// one that did, or is the whole (1).
public struct JobProgress: Sendable {
    let reporter: ProgressReporter

    public func report(_ fraction: Double) {
        reporter.report(fraction)
    }
}

/// The progress of one run of a job: what it last published, and where it sends what it publishes, in order.
final class ProgressReporter: Sendable {
    /// The smallest step that is published.
    static let step = 0.01

    private let published = Mutex(0.0)
    private let continuation: AsyncStream<Double>.Continuation

    init(_ continuation: AsyncStream<Double>.Continuation) {
        self.continuation = continuation
    }

    func report(_ fraction: Double) {
        guard !fraction.isNaN else { return }
        let value = min(max(fraction, 0), 1)
        // Published under the lock, so two threads reporting at once publish in the order they passed the check.
        published.withLock { last in
            guard value >= last + Self.step || (value == 1 && last < 1) else { return }
            last = value
            continuation.yield(value)
        }
    }

    /// The run is over: nothing more is published.
    func finish() {
        continuation.finish()
    }
}

/// The work of a job: it reads its sources, writes its cache file whole (`ProjectCaches.temporaryFile`,
/// `ProjectCaches.commit`) or makes the words, and returns what it made. It runs on a task of its own at utility
/// priority; when that task is cancelled (the job was cancelled, or a take started recording) it stops as soon as it
/// can and leaves no part of a file behind. A job asked for again runs its work again from the start, which finds its
/// cache file if it got that far.
public typealias JobWork = @Sendable (JobProgress) async throws -> JobOutput
