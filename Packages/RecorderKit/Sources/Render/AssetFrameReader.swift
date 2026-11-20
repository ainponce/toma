// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import Dispatch
import Foundation
import ProjectFormat
import Synchronization

/// The reader of a clip of the user's own, a video of the package's `assets/` (phase 3 design §5.4, plan 3a decision 12):
/// a `TrackFrameReader` of the file (`init(maskFile:trackID:start:end:)`), its frames at the host times of its file's own
/// presentation times from 0, so a frame is asked for at the file's time (`MediaClipLayer.fileTime`). It is read as the
/// screens are, through the renderer's readers and prefetchers (`FrameRenderer.reader(for:)`, `mediaReader(for:)`), by a
/// reader id no track of a take has: `asset:` and the path the document names it by (a track's id is letters, digits and
/// `-`). So it decodes where the take's videos decode, ahead in the preview and the export alike, in the export's slot of
/// the process's decoding slots (`DecodingSlots`), and blocks as they block.
///
/// The file is found only through the package's safe reader (`ProjectPackage.mediaAsset(_:as:)`, `.video`): one that is
/// not a regular file of `assets/` reached through no link gives no reader, so its clip draws the background alone.
public enum AssetFrameReader {
    /// What every reader id of a clip starts with.
    static let prefix = "asset:"

    /// The reader id of the clip `asset` (`assets/<sha>.<mov|mp4|m4v>`): `asset:<asset>`.
    public static func readerID(of asset: String) -> String {
        prefix + asset
    }

    /// The clip a reader id of `readerID(of:)` names, or of one of the readers of the clips over the video
    /// (`FrameRenderer.overlayReaderID(of:lane:)`, `asset:<path>#overlay…`: a path of `assets/` has no `#`); `nil` for any
    /// other id (a track's, a person's mask's).
    public static func asset(ofReaderID id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        let asset = id.dropFirst(prefix.count).prefix { $0 != "#" }
        return asset.isEmpty ? nil : String(asset)
    }

    /// A reader of the clip `asset` of `package` where it is now, as `ProjectPackage.mediaAsset(_:as:)` gives it; `nil`
    /// when that gives nothing (not a video of `assets/`, gone, a link, too large). Opens nothing yet.
    static func make(asset: String, package: ProjectPackage) -> TrackFrameReader? {
        guard let url = package.mediaAsset(asset, as: .video) else { return nil }
        return TrackFrameReader(maskFile: url, trackID: readerID(of: asset), start: HostTime(nanoseconds: 0), end: nil)
    }

    /// How a player turns the frames of the movie at `url` upright: its first video track's `preferredTransform`
    /// (`MediaOrientation`), loaded within `TrackFrameReader.trackLoadTimeout`; `nil` when it cannot be loaded then. Blocks
    /// the caller meanwhile, as a reader's first frame does (never call it from a Swift concurrency thread); AVFoundation
    /// reads the movie's header for it.
    static func orientation(of url: URL) -> MediaOrientation? {
        let done = DispatchSemaphore(value: 0)
        let box = OrientationBox()
        Task.detached(priority: .userInitiated) {
            defer { done.signal() }
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let transform = try? await track.load(.preferredTransform)
            else { return }
            box.set(MediaOrientation(transform))
        }
        guard done.wait(timeout: .now() + TrackFrameReader.trackLoadTimeout) == .success else { return nil }
        return box.get()
    }
}

/// The orientation `AssetFrameReader.orientation(of:)` loads, handed from its task to the caller waiting for it.
private final class OrientationBox: Sendable {
    private let value = Mutex<MediaOrientation?>(nil)

    func set(_ orientation: MediaOrientation) { value.withLock { $0 = orientation } }
    func get() -> MediaOrientation? { value.withLock { $0 } }
}

/// How the decoded frames of a clip are turned upright as a player shows them (its video track's `preferredTransform`),
/// as the texture coordinates of the upright picture: `origin` at its top-left corner, `across` per unit of its width and
/// `down` per unit of its height, so the texel under the fraction `(s, t)` of the picture is at `origin + s × across +
/// t × down` of the frame. A quarter turn either way, a half turn and a mirror (any transform whose linear part maps the
/// frame's axes onto the picture's, whatever its scale and its move); any other transform is drawn as decoded.
struct MediaOrientation: Equatable, Sendable {
    var origin: SIMD2<Float>
    var across: SIMD2<Float>
    var down: SIMD2<Float>

    /// As decoded.
    static let upright = MediaOrientation(origin: .zero, across: [1, 0], down: [0, 1])

    init(origin: SIMD2<Float>, across: SIMD2<Float>, down: SIMD2<Float>) {
        self.origin = origin
        self.across = across
        self.down = down
    }

    /// The upright picture of a frame shown through `transform` (in the frame's pixels, y down, as AVFoundation reads a
    /// track's): what the inverse of its linear part sends the picture's axes to, by their signs alone, the scale and the
    /// move left out; `upright` for a transform that is not finite, cannot be inverted or does not keep the axes.
    init(_ transform: CGAffineTransform) {
        let (a, b, c, d) = (Double(transform.a), Double(transform.b), Double(transform.c), Double(transform.d))
        let scale = max(abs(a), abs(b), abs(c), abs(d))
        let small = 1e-6 * scale
        let straight = abs(b) <= small && abs(c) <= small && abs(a) > small && abs(d) > small
        let turned = abs(a) <= small && abs(d) <= small && abs(b) > small && abs(c) > small
        let determinant = a * d - b * c
        guard [a, b, c, d].allSatisfy(\.isFinite), scale > 0, straight || turned, determinant.isFinite, determinant != 0 else {
            self = .upright
            return
        }
        /// The sign of an entry of the inverse, 0 for one that is 0 (`small` before the determinant divides it).
        func sign(_ x: Double) -> Float {
            abs(x) <= small ? 0 : (x / determinant > 0 ? 1 : -1)
        }
        // The inverse of [[a, c], [b, d]] is [[d, −c], [−b, a]] / determinant: its columns, the picture's axes in the frame.
        let across = SIMD2(sign(d), sign(-b)), down = SIMD2(sign(-c), sign(a))
        // Along each of the frame's axes, a picture's axis going backwards starts at the far side.
        let origin = SIMD2<Float>(across.x < 0 || down.x < 0 ? 1 : 0, across.y < 0 || down.y < 0 ? 1 : 0)
        self.init(origin: origin, across: across, down: down)
    }

    /// Whether the picture's width runs along the frame's height: a quarter turn.
    var swapsSides: Bool { across.x == 0 }

    /// The size of the upright picture of a frame `size` big.
    func uprightSize(of size: SIMD2<Double>) -> SIMD2<Double> {
        swapsSides ? SIMD2(size.y, size.x) : size
    }
}
