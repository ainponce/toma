// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Darwin
import Foundation

/// An image file a package holds for the editor to draw, each kind with its own folder, name rule and limits
/// (design §6.1). A file that breaks them is treated as absent.
public enum PackageFileKind: Sendable {
    /// `takes/<take>/cursors/<32 lowercase hex>.png`: an image of the cursor a take recorded.
    case cursorImage
    /// `takes/<take>/wallpapers/display-<id>.png`: the wallpaper of a display as the take started.
    case wallpaper
    /// `assets/<32 lowercase hex>.<png|jpg|heic|tiff>`: an image of the user's own, copied into the package.
    case asset

    /// The largest file read.
    public var maxBytes: Int {
        switch self {
        case .cursorImage: 1_048_576
        case .wallpaper: 67_108_864
        case .asset: 104_857_600
        }
    }

    /// The largest width or height decoded.
    public var maxPixelSide: Int {
        switch self {
        case .cursorImage: 512
        case .wallpaper, .asset: 16_384
        }
    }

    /// The image formats decoded for this kind, as the uniform type identifiers ImageIO reads from the content:
    /// PNG for cursors and wallpaper photos, which Toma writes; PNG, JPEG and HEIC for the user's own. A package can
    /// come from anywhere, so no other decoder of ImageIO is reached from it, whatever a file's name says. An asset
    /// named `.tiff`, which `isValidName` allows, is not decoded.
    public var imageTypes: Set<String> {
        switch self {
        case .cursorImage, .wallpaper: ["public.png"]
        case .asset: ["public.png", "public.jpeg", "public.heic"]
        }
    }

    /// Whether `name`, a file name with no folder, is exactly what this kind's files are called:
    /// `^[0-9a-f]{32}\.png$`, `^display-[0-9]+\.png$` or `^[0-9a-f]{32}\.(png|jpg|heic|tiff)$`, in ASCII.
    public func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        switch self {
        case .cursorImage:
            return Self.isHash(bytes, withExtensionIn: ["png"])
        case .asset:
            return Self.isHash(bytes, withExtensionIn: ["png", "jpg", "heic", "tiff"])
        case .wallpaper:
            let prefix = Array("display-".utf8)
            let suffix = Array(".png".utf8)
            guard bytes.count > prefix.count + suffix.count, bytes.starts(with: prefix), bytes.suffix(suffix.count) == suffix[...]
            else { return false }
            return bytes[prefix.count..<(bytes.count - suffix.count)].allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        }
    }

    /// Whether `folders`, the path components before the file's name, are the folder this kind's files live in.
    fileprivate func livesIn(_ folders: ArraySlice<String>) -> Bool {
        switch self {
        case .cursorImage, .wallpaper:
            guard folders.count == 3, folders[folders.startIndex] == "takes",
                  (try? ProjectPackage.validateTakeID(folders[folders.startIndex + 1])) != nil
            else { return false }
            return folders[folders.startIndex + 2] == (self == .cursorImage ? "cursors" : "wallpapers")
        case .asset:
            return folders.elementsEqual(["assets"])
        }
    }

    /// 32 lowercase hex digits, a `.` and one of `extensions`.
    private static func isHash(_ bytes: [UInt8], withExtensionIn extensions: [String]) -> Bool {
        guard bytes.count > 33, bytes[32] == UInt8(ascii: "."),
              bytes[..<32].allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) })
        else { return false }
        return extensions.contains { bytes[33...].elementsEqual($0.utf8) }
    }
}

/// Reads a file of a package without trusting the package: nothing inside it is followed if it is a symlink, nothing
/// that is not a regular file is read (a FIFO would never answer), and nothing larger than its kind allows.
///
/// Never `Data(contentsOf:)`, which follows links and waits forever on a FIFO.
public enum SafePackageFile {
    /// The bytes of the file at `relativePath` of `package` (`takes/take-001/cursors/<hash>.png`), or `nil` if the
    /// path is not where a file of `kind` lives or its name breaks the kind's rule, if a folder or the file inside
    /// the package is a symlink, if the file is not a regular file, if it is larger than `kind.maxBytes` or if
    /// reading it fails.
    ///
    /// The package's own folder may be reached through links (the user's, or `/var`); every component after it is
    /// opened with `openat` and `O_NOFOLLOW` from the folder before it, so a link swapped in midway is never followed
    /// either.
    public static func read(_ relativePath: String, in package: ProjectPackage, as kind: PackageFileKind) -> Data? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = components.last, kind.isValidName(name), kind.livesIn(components.dropLast()) else { return nil }

        var folder = retryingInterrupts { open(package.url.path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC) }
        guard folder >= 0 else { return nil }
        for component in components.dropLast() {
            let next = retryingInterrupts { openat(folder, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            close(folder)
            guard next >= 0 else { return nil }
            folder = next
        }
        // `O_NONBLOCK`: opening a FIFO for reading would otherwise wait for a writer that never comes.
        let fd = retryingInterrupts { openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        close(folder)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= kind.maxBytes else { return nil }
        return readWhole(fd, size: Int(info.st_size))
    }

    /// Exactly `size` bytes from `fd` up to its end, or `nil` if reading fails or the file is no longer `size` bytes.
    private static func readWhole(_ fd: Int32, size: Int) -> Data? {
        // One byte more than `fstat` said: a file that grew since is not the file that was measured.
        var data = Data(count: size + 1)
        let count = data.withUnsafeMutableBytes { buffer -> Int? in
            guard let base = buffer.baseAddress else { return nil }
            var filled = 0
            while filled < buffer.count {
                let read = Darwin.read(fd, base + filled, buffer.count - filled)
                if read > 0 {
                    filled += read
                } else if read == 0 {
                    break
                } else if errno != EINTR {
                    return nil
                }
            }
            return filled
        }
        guard count == size else { return nil }
        data.count = size
        return data
    }

    private static func retryingInterrupts(_ call: () -> Int32) -> Int32 {
        while true {
            let fd = call()
            if fd >= 0 || errno != EINTR { return fd }
        }
    }
}

extension ProjectPackage {
    /// The longest side `wallpaper(take:displayID:)` and `asset(_:)` decode to: twice the largest output, 4K (3 840).
    private static let largestDecodedSide = 2 * 3_840

    /// The image `takes/<take>/cursors/<hash>.png`, a `cursorImage` event's, or `nil` if it is absent or breaks the
    /// rules of `PackageFileKind.cursorImage`. `hash` and `take` come from the package and are checked whole before
    /// anything is opened: a `hash` with a `/` or `..`, or one in capitals, names no file.
    public func cursorImage(take: String, hash: String) -> CGImage? {
        image(at: "takes/\(take)/cursors/\(hash).png", as: .cursorImage)
    }

    /// The image `takes/<take>/wallpapers/display-<displayID>.png` decoded with its longer side reduced to 7 680 pixels
    /// at most, or `nil` if it is absent or breaks the rules of `PackageFileKind.wallpaper`.
    public func wallpaper(take: String, displayID: UInt32) -> CGImage? {
        image(at: "takes/\(take)/wallpapers/display-\(displayID).png", as: .wallpaper, reducedTo: Self.largestDecodedSide)
    }

    /// The image `file` (`"assets/<sha>.<ext>"`, as the document names it) decoded with its longer side reduced to
    /// 7 680 pixels at most and turned upright by its EXIF orientation, or `nil` if it is absent or breaks the rules
    /// of `PackageFileKind.asset`.
    public func asset(_ file: String) -> CGImage? {
        image(at: file, as: .asset, reducedTo: Self.largestDecodedSide)
    }

    /// Each image comes out as `BoundedImage.decode` gives it: 8-bit RGBA with premultiplied alpha.
    private func image(at relativePath: String, as kind: PackageFileKind, reducedTo longSide: Int? = nil) -> CGImage? {
        guard let data = SafePackageFile.read(relativePath, in: self, as: kind) else { return nil }
        return BoundedImage.decode(data, maxPixelSide: kind.maxPixelSide, reducedTo: longSide, allowedTypes: kind.imageTypes)
    }
}
