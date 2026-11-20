// SPDX-License-Identifier: GPL-3.0-or-later

/// The arrow keys over the preview with annotations chosen (phase 3 plan 3a, decision 16): ← → ↑ ↓ move them 1 point of
/// the preview, ⇧ 10; the playhead stays. Pure: `KeyboardCommands` gives the same commands it always did, and the app,
/// with annotations chosen and the focus on the preview, asks for the nudge of the command before running it.
public enum AnnotationKeys {
    /// How far `command` moves what is chosen, in points of the preview (x right, y down); `nil` if it is not an arrow key.
    public static func nudge(for command: EditorCommand) -> SIMD2<Double>? {
        switch command {
        case let .step(frames): SIMD2(Double(frames), 0)
        case let .stepSeconds(seconds): SIMD2(Double(seconds) * 10, 0)
        case .previousEditPoint: SIMD2(0, -1)
        case .nextEditPoint: SIMD2(0, 1)
        case let .nudgeVertically(points): SIMD2(0, Double(points))
        default: nil
        }
    }
}
