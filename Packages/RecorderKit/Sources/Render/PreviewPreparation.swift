// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Foundation
import ProjectFormat

/// A take read from disk with its preview ready to draw: the first segment's track is loaded and its
/// first frame decoded.
public struct PreparedPreview: Sendable {
    public var project: LoadedProject
    public var preview: PreviewRenderer
    /// Output seconds the take lasts.
    public var duration: Double

    public init(project: LoadedProject, preview: PreviewRenderer, duration: Double) {
        self.project = project
        self.preview = preview
        self.duration = duration
    }
}

public enum PreviewPreparationError: Error, Equatable {
    /// Take `takeID` is still marked `recording`: it is being recorded, or its recorder died and it must be
    /// recovered first.
    case unfinished(takeID: String)
    /// The first frame could not be drawn; the error, described.
    case cannotDraw(String)
}

/// Prepares editor previews without ever blocking a Swift concurrency thread.
///
/// Loading a take and decoding its first frame block (`AVAssetReader.copyNextSampleBuffer` waits on
/// AVFoundation's own work). Done on the cooperative pool, as many preparations at once as it has threads
/// leave no thread for anything else: every other task of the app, a recording's actors included, stops.
/// So the work runs on one serial dispatch queue, one preview at a time, and the caller only awaits it.
public enum PreviewPreparation {
    /// Where every preparation runs, one at a time. GCD gives a queue a thread of its own when it needs one.
    static let queue = DispatchQueue(label: "dev.toma.EditorPrepare", qos: .userInitiated)

    /// Reads take `take` of the package at `url` (the last one when `nil`) and prepares its preview at
    /// `outputSize`, on `queue`, of `document` (the take's legacy document, `EditDocument.legacy(for:)`, when `nil`).
    /// - Throws: `PreviewPreparationError.unfinished` for a take the preview shows marked `recording` (any take of the
    ///   package `document`'s sequence shows, `LoadedProject.takesShown(by:)`: the take itself for the legacy document),
    ///   `cannotDraw` if its first frame cannot be drawn, and the errors of `LoadedProject.load` and `FrameRenderer.init`.
    public static func prepare(
        url: URL, take: String?, outputSize: SIMD2<Int>, document: EditDocument? = nil
    ) async throws -> PreparedPreview {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try prepareBlocking(url: url, take: take, outputSize: outputSize, document: document)
                })
            }
        }
    }

    /// `prepare`, on the caller's thread. Blocks: never call it from a Swift concurrency thread.
    static func prepareBlocking(
        url: URL, take: String?, outputSize: SIMD2<Int>, document: EditDocument? = nil
    ) throws -> PreparedPreview {
        let project = try LoadedProject.load(url, take: take)
        let document = document ?? .legacy(for: project)
        for shown in project.takesShown(by: document) where shown.take.status == .recording {
            throw PreviewPreparationError.unfinished(takeID: shown.take.id)
        }
        // Its own renderer: an export makes another one.
        let renderer = try FrameRenderer(project: project, document: document, outputSize: outputSize)
        let preview = PreviewRenderer(renderer: renderer)
        do {
            _ = try preview.snapshot(at: 0)  // loads the first segment's track now
        } catch {
            throw PreviewPreparationError.cannotDraw(String(describing: error))
        }
        return PreparedPreview(project: project, preview: preview, duration: renderer.duration)
    }
}
