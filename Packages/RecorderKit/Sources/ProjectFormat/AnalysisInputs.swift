// SPDX-License-Identifier: GPL-3.0-or-later

/// What the render and the mix read of the project's analysis caches (phase 2 design §10): the person's masks, the faces,
/// the cleaned sound, the loudness. They never call Vision, Speech or an Audio Unit themselves (phase 2 rules, "render
/// determinista"): whoever makes a renderer, an export or a mix finds what the caches hold and hands it over in one of
/// these, and a frame or a sample is a function of it, the package and the document.
///
/// Empty in the base of phase 2 (`none`): with it, everything draws and sounds as in phase 1. Each feature adds its field
/// at the end, with its empty value by default, so no caller changes (a shared file, only for adding).
public struct AnalysisInputs: Equatable, Sendable {
    public init() {}

    /// Nothing read from the caches: what every phase-1 caller passes.
    public static let none = AnalysisInputs()

    /// The voice without noise of each audio track that has it for every segment heard, by `AudioPlan.key(take:track:)`
    /// (phase 2 design §5.6). Empty: every track sounds as recorded.
    public var cleanVoice: [String: CleanVoice] = [:]
    /// The loudness measure of each audio track that was measured whole, by `AudioPlan.key(take:track:)` (phase 2 design
    /// §5.7). Empty: nothing is normalized.
    public var loudness: [String: TrackLoudness] = [:]
}
