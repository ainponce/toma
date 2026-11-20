// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Darwin
import Foundation

/// A file a package holds for the editor (an image, a camera look's `.cube`, a clip, a sound, the script), each kind with
/// its own folder, name rule and limits (design §6.1; phase 2 design §6.3; phase 3 design §5.4, §7.7, §8.5). A file that
/// breaks them is treated as absent.
public enum PackageFileKind: Sendable {
    /// `takes/<take>/cursors/<32 lowercase hex>.png`: an image of the cursor a take recorded.
    case cursorImage
    /// `takes/<take>/wallpapers/display-<id>.png`: the wallpaper of a display as the take started.
    case wallpaper
    /// `assets/<32 lowercase hex>.<png|jpg|heic|tiff>`: an image of the user's own, copied into the package.
    case asset
    /// `assets/<32 lowercase hex>.cube`: a 3D LUT of the user's own for the camera (`CameraColor.lut`), copied into the
    /// package. Text, parsed by `CubeLUT.parse`: never decoded as an image.
    case lut
    /// `assets/<32 lowercase hex>.<mov|mp4|m4v>`: a clip of the user's own (H.264, HEVC or ProRes), copied into the
    /// package (phase 3). Read by AVFoundation from its URL, only once `ProjectPackage.mediaAsset(_:as:)` gave it.
    case video
    /// `assets/<32 lowercase hex>.<m4a|mp3|wav|aiff|caf>`: a sound of the user's own (an `.aif` is named `aiff`), copied
    /// into the package (phase 3), as `video` is read.
    case audio
    /// `script.txt` at the root of the package: the teleprompter's script of the project, UTF-8 (phase 3 design §8.5).
    case script

    /// The largest file read: for a clip or a sound, the largest one handed on to AVFoundation.
    public var maxBytes: Int {
        switch self {
        case .cursorImage: 1_048_576
        case .wallpaper: 67_108_864
        case .asset: 104_857_600
        case .lut: CubeLUT.maxBytes
        case .video: 17_179_869_184
        case .audio: 2_147_483_648
        case .script: 1_048_576
        }
    }

    /// The largest width or height decoded; 0 for a `.cube`, a clip, a sound or the script, which are no image.
    public var maxPixelSide: Int {
        switch self {
        case .cursorImage: 512
        case .wallpaper, .asset: 16_384
        case .lut, .video, .audio, .script: 0
        }
    }

    /// The image formats decoded for this kind, as the uniform type identifiers ImageIO reads from the content:
    /// PNG for cursors and wallpaper photos, which Toma writes; PNG, JPEG and HEIC for the user's own. A package can
    /// come from anywhere, so no other decoder of ImageIO is reached from it, whatever a file's name says. An asset
    /// named `.tiff`, which `isValidName` allows, is not decoded. None for a `.cube`, a clip, a sound or the script.
    public var imageTypes: Set<String> {
        switch self {
        case .cursorImage, .wallpaper: ["public.png"]
        case .asset: ["public.png", "public.jpeg", "public.heic"]
        case .lut, .video, .audio, .script: []
        }
    }

    /// Whether `name`, a file name with no folder, is exactly what this kind's files are called:
    /// `^[0-9a-f]{32}\.png$`, `^display-[0-9]+\.png$`, `^[0-9a-f]{32}\.(png|jpg|heic|tiff)$`, `^[0-9a-f]{32}\.cube$`,
    /// `^[0-9a-f]{32}\.(mov|mp4|m4v)$`, `^[0-9a-f]{32}\.(m4a|mp3|wav|aiff|caf)$` or `^script\.txt$`, in ASCII.
    public func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        switch self {
        case .cursorImage:
            return Self.isHash(bytes, withExtensionIn: ["png"])
        case .asset:
            return Self.isHash(bytes, withExtensionIn: ["png", "jpg", "heic", "tiff"])
        case .lut:
            return Self.isHash(bytes, withExtensionIn: ["cube"])
        case .video:
            return Self.isHash(bytes, withExtensionIn: ["mov", "mp4", "m4v"])
        case .audio:
            return Self.isHash(bytes, withExtensionIn: ["m4a", "mp3", "wav", "aiff", "caf"])
        case .script:
            return name == Self.scriptFileName
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
        case .asset, .lut, .video, .audio:
            return folders.elementsEqual(["assets"])
        case .script:
            return folders.isEmpty
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
        guard let (folder, name) = openFolder(of: relativePath, in: package, as: kind) else { return nil }
        // `O_NONBLOCK`: opening a FIFO for reading would otherwise wait for a writer that never comes.
        let fd = retryingInterrupts { openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        close(folder)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= kind.maxBytes else { return nil }
        return readWhole(fd, size: Int(info.st_size))
    }

    /// Where the file at `relativePath` of `package` is now, for a reader that opens it by its path (AVFoundation), if
    /// `read` would read it: the path is where a file of `kind` lives and its name the kind's, no folder inside the
    /// package nor the file is a symlink (each reached with `openat` and `O_NOFOLLOW` from the one before it, as `read`
    /// does), and the file is a regular one of at most `kind.maxBytes`, looked at with `fstatat` and
    /// `AT_SYMLINK_NOFOLLOW` without opening it (a FIFO is never opened). `nil` otherwise.
    ///
    /// What is there can still change after this looked: whoever reads it keeps to what it finds then.
    static func checkedURL(_ relativePath: String, in package: ProjectPackage, as kind: PackageFileKind) -> URL? {
        let root = package.currentURL
        guard let (folder, name) = openFolder(of: relativePath, in: package, as: kind, root: root) else { return nil }
        defer { close(folder) }
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= kind.maxBytes
        else { return nil }
        return root.appending(path: relativePath, directoryHint: .notDirectory)
    }

    /// The folder `relativePath` of `package` ends in, open, and the file's name in it, if the path is where a file of
    /// `kind` lives and its name is the kind's: the package's folder where it is now (`root`, by default
    /// `ProjectPackage.currentURL`: it may have been renamed since it was opened), then every component after it with
    /// `openat` and `O_NOFOLLOW` from the folder before it. The caller closes it.
    private static func openFolder(
        of relativePath: String, in package: ProjectPackage, as kind: PackageFileKind, root: URL? = nil
    ) -> (folder: Int32, name: String)? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = components.last, kind.isValidName(name), kind.livesIn(components.dropLast()) else { return nil }

        var folder = retryingInterrupts { open((root ?? package.currentURL).path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC) }
        guard folder >= 0 else { return nil }
        for component in components.dropLast() {
            let next = retryingInterrupts { openat(folder, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            close(folder)
            guard next >= 0 else { return nil }
            folder = next
        }
        return (folder, name)
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

extension PackageFileKind {
    /// The longest side a wallpaper photo or an asset is decoded to: twice the largest output, 4K (3 840).
    public static let largestDecodedSide = 2 * 3_840

    /// The image of `data`, the bytes of a file of this kind, decoded as the package's readers decode it
    /// (`BoundedImage.decode` with this kind's formats and size): a cursor image as stored, a wallpaper photo or an asset
    /// reduced to `largestDecodedSide`. `nil` if it does not decode so. The one rule, so a file the editor takes in (an
    /// imported image) is one the render draws.
    public func decodedImage(_ data: Data) -> CGImage? {
        let longSide = self == .cursorImage ? nil : Self.largestDecodedSide
        return BoundedImage.decode(data, maxPixelSide: maxPixelSide, reducedTo: longSide, allowedTypes: imageTypes)
    }
}

extension ProjectPackage {

    /// The image `takes/<take>/cursors/<hash>.png`, a `cursorImage` event's, or `nil` if it is absent or breaks the
    /// rules of `PackageFileKind.cursorImage`. `hash` and `take` come from the package and are checked whole before
    /// anything is opened: a `hash` with a `/` or `..`, or one in capitals, names no file.
    public func cursorImage(take: String, hash: String) -> CGImage? {
        image(at: "takes/\(take)/cursors/\(hash).png", as: .cursorImage)
    }

    /// The image `takes/<take>/wallpapers/display-<displayID>.png` decoded with its longer side reduced to 7 680 pixels
    /// at most, or `nil` if it is absent or breaks the rules of `PackageFileKind.wallpaper`.
    public func wallpaper(take: String, displayID: UInt32) -> CGImage? {
        image(at: "takes/\(take)/wallpapers/display-\(displayID).png", as: .wallpaper)
    }

    /// The image `file` (`"assets/<sha>.<ext>"`, as the document names it) decoded with its longer side reduced to
    /// 7 680 pixels at most and turned upright by its EXIF orientation, or `nil` if it is absent or breaks the rules
    /// of `PackageFileKind.asset`.
    public func asset(_ file: String) -> CGImage? {
        image(at: file, as: .asset)
    }

    /// Each image comes out as `PackageFileKind.decodedImage` gives it: 8-bit RGBA with premultiplied alpha.
    private func image(at relativePath: String, as kind: PackageFileKind) -> CGImage? {
        SafePackageFile.read(relativePath, in: self, as: kind).flatMap(kind.decodedImage)
    }

    /// Where the clip or the sound `file` (`"assets/<sha>.<ext>"`, as the document names it) is now, for `AVURLAsset`,
    /// which is never given a path of the package before this: `nil` unless `kind` is `.video` or `.audio` and the file
    /// is one of that kind, in `assets/`, a regular file within its size, reached through no link
    /// (`SafePackageFile`). It is not opened here.
    public func mediaAsset(_ file: String, as kind: PackageFileKind) -> URL? {
        switch kind {
        case .video, .audio: SafePackageFile.checkedURL(file, in: self, as: kind)
        case .cursorImage, .wallpaper, .asset, .lut, .script: nil
        }
    }

    /// The project's script, `script.txt` (design §8.5), whole, or `nil` if it is not there, is a link or not a regular
    /// file, is larger than 1 MiB (`PackageFileKind.script.maxBytes`) or is not UTF-8.
    public func readScript() -> String? {
        guard let data = SafePackageFile.read(PackageFileKind.scriptFileName, in: self, as: .script) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the project's script, `script.txt`, with `text`, whole and atomically
    /// (`DurableFile.writeAtomically(_:named:inDirectory:)` from a descriptor of the package's folder, where it is now):
    /// a reader sees the old script or the new one, and a link there is replaced, never followed. Throws `EFBIG`, with
    /// nothing written, for a text of more than 1 MiB in UTF-8 (`PackageFileKind.script.maxBytes`), and the `POSIXError`
    /// of a call that fails.
    public func writeScript(_ text: String) throws {
        let data = Data(text.utf8)
        guard data.count <= PackageFileKind.script.maxBytes else { throw POSIXError(.EFBIG) }
        let folder = open(currentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else { throw POSIXError.current() }
        defer { close(folder) }
        try DurableFile.writeAtomically(data, named: PackageFileKind.scriptFileName, inDirectory: folder)
    }
}

extension PackageFileKind {
    /// `script.txt`, the name of the project's script at the root of the package.
    static let scriptFileName = "script.txt"
}
