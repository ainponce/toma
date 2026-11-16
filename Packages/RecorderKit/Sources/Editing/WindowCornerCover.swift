// SPDX-License-Identifier: GPL-3.0-or-later

/// The corners that hide the black ones of a window take (plan decision 12, design §7.3). A capture of a window records
/// the window's rounded corners in black, with a radius that depends on the macOS that recorded it, which the format
/// does not keep; the screen's corners cover them when they are at least that radius on the drawn window. A new project
/// of a window take starts with corners that cover `blackCornerPoints` of it (`NewDocument`): covering more only rounds
/// more.
public enum WindowCornerCover {
    /// The radius of the black corners covered, in points of the window: provisional until the owner measures those of
    /// macOS 15 and 26 (`docs/release.md`).
    public static let blackCornerPoints = 26.0

    /// The corner radius as a fraction of the output's width (`StageStyle.cornerRadius`) that covers `blackCornerPoints`
    /// of a window `windowWidthPoints` wide drawn into a screen rect `screenRectWidth` wide (output pixels) of an output
    /// `outputWidth` wide; 0 when one of them is not finite and above 0.
    public static func cornerRadius(windowWidthPoints: Double, screenRectWidth: Double, outputWidth: Double) -> Double {
        guard [windowWidthPoints, screenRectWidth, outputWidth].allSatisfy({ $0.isFinite && $0 > 0 }) else { return 0 }
        return blackCornerPoints / windowWidthPoints * screenRectWidth / outputWidth
    }
}
