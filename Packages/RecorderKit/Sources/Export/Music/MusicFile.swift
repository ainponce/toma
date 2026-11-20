// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// The file of a theme of the music library (plan decision 4): a Core Audio Format file of our own making, linear PCM
/// in 32-bit floats, little-endian, two channels interleaved, at 48 kHz, with only its `desc` and `data` chunks. So its
/// bytes are always the same for the same samples, and `AVAudioFile` (and anything that reads CAF) plays it.
///
/// The 68 bytes before the samples (all big-endian, as CAF wants, but the samples):
///
/// | Bytes | What |
/// |---|---|
/// | 0–7 | `caff`, version 1, flags 0 |
/// | 8–19 | the `desc` chunk's type and size, 32 |
/// | 20–51 | 48 000.0 (`Float64`), `lpcm`, flags 3 (float, little-endian), 8 bytes a packet, 1 frame a packet, 2 channels, 32 bits a channel |
/// | 52–63 | the `data` chunk's type and size, 4 + 8 × frames |
/// | 64–67 | its edit count, 0 |
///
/// A file is ours only if its 68 bytes are exactly these for the frames its size says; anything else (another CAF, one
/// cut short, a link) is not, and its theme is made again.
public struct MusicFile: Sendable {
    public static let channels = 2
    public static let sampleRate = 48_000
    /// The bytes before the samples.
    public static let headerBytes = 68
    /// The bytes of a frame: two `Float32`.
    public static let frameBytes = 8

    /// The frames of the file.
    public let frames: Int
    private let mapping: Mapping

    // MARK: Writing

    /// The 68 bytes that come before `frames` frames.
    public static func header(frames: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerBytes)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
        }
        bytes.append(contentsOf: Array("caff".utf8))
        append(UInt16(1))
        append(UInt16(0))
        bytes.append(contentsOf: Array("desc".utf8))
        append(Int64(32))
        append(Double(sampleRate).bitPattern)
        bytes.append(contentsOf: Array("lpcm".utf8))
        append(UInt32(3)) // kCAFLinearPCMFormatFlagIsFloat | kCAFLinearPCMFormatFlagIsLittleEndian
        append(UInt32(frameBytes))
        append(UInt32(1))
        append(UInt32(channels))
        append(UInt32(32))
        bytes.append(contentsOf: Array("data".utf8))
        append(Int64(4 + frameBytes * frames))
        append(UInt32(0))
        return bytes
    }

    /// The whole file of `interleaved` (left, right, left…).
    /// - Precondition: an even number of samples.
    public static func data(interleaved: [Float]) -> Data {
        precondition(interleaved.count % channels == 0, "MusicFile: an odd number of samples")
        var data = Data(header(frames: interleaved.count / channels))
        data.reserveCapacity(headerBytes + 4 * interleaved.count)
        for sample in interleaved {
            withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Writes the file of `interleaved` at `url`, replacing what is there but never following a link there (`ELOOP`).
    /// Not atomic and not synced: the music library writes a temporary this way and moves it into place. A write that
    /// fails throws and leaves nothing at `url`. Never on the main thread.
    /// - Precondition: an even number of samples.
    public static func write(interleaved: [Float], to url: URL) throws {
        precondition(interleaved.count % channels == 0, "MusicFile: an odd number of samples")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError.current }
        var failure: POSIXError?
        let header = Self.header(frames: interleaved.count / channels)
        header.withUnsafeBytes { if !writeAll(fd, $0) { failure = .current } }
        if failure == nil {
            // In pieces of 64 Ki samples, each turned little-endian (a no-op on Apple silicon).
            var piece = [UInt32](repeating: 0, count: 65_536)
            var offset = 0
            while offset < interleaved.count, failure == nil {
                let count = min(piece.count, interleaved.count - offset)
                for i in 0..<count { piece[i] = interleaved[offset + i].bitPattern.littleEndian }
                piece.withUnsafeBytes { if !writeAll(fd, UnsafeRawBufferPointer(rebasing: $0[..<(count * 4)])) { failure = .current } }
                offset += count
            }
        }
        if close(fd) != 0, failure == nil { failure = .current }
        if let failure {
            unlink(url.path)
            throw failure
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        guard var next = bytes.baseAddress else { return true }
        var remaining = bytes.count
        while remaining > 0 {
            let count = Darwin.write(fd, next, remaining)
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            next += count
            remaining -= count
        }
        return true
    }

    // MARK: Reading

    /// The file at `url`, mapped into memory (its pages are read as they are needed): `ELOOP` for a link (never
    /// followed), `EFTYPE` for anything else that is not a regular file, `MusicFileError.notOurs` for a file whose 68
    /// bytes are not exactly ours for the frames its size says.
    ///
    /// The mapping is of the file as it was opened: a file moved over it later (the library makes a theme again with
    /// `rename`) does not change it.
    public init(contentsOf url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError.current }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError.current }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        let size = Int(info.st_size)
        guard let frames = Self.frames(ofSize: size), Self.readHeader(fd) == Self.header(frames: frames) else {
            throw MusicFileError.notOurs
        }
        guard let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), base != MAP_FAILED else { throw POSIXError.current }
        self.frames = frames
        mapping = Mapping(base: base, size: size)
    }

    /// Whether the file at `url` is ours with exactly `frames` frames, by its size and its 68 bytes alone (it reads
    /// nothing more): a link is not followed and is not.
    public static func isOurs(at url: URL, frames: Int) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Self.frames(ofSize: Int(info.st_size)) == frames else {
            return false
        }
        return readHeader(fd) == header(frames: frames)
    }

    /// The frames of a file of `size` bytes, if that is a header and whole frames.
    private static func frames(ofSize size: Int) -> Int? {
        guard size >= headerBytes, (size - headerBytes) % frameBytes == 0 else { return nil }
        return (size - headerBytes) / frameBytes
    }

    /// The first 68 bytes of `fd`, or fewer if it ends before.
    private static func readHeader(_ fd: Int32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: headerBytes)
        let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, headerBytes, 0) }
        return count == headerBytes ? bytes : []
    }

    /// Frames `range` of the file, interleaved, into `samples`, which ends up with exactly `2 × range.count` samples;
    /// frames before 0 or after the last are silence.
    public func read(_ range: Range<Int>, into samples: inout [Float]) {
        let count = 2 * range.count
        if samples.count != count {
            samples.removeAll(keepingCapacity: true)
            samples.append(contentsOf: repeatElement(0, count: count))
        }
        let first = max(range.lowerBound, 0), last = min(range.upperBound, frames)
        samples.withUnsafeMutableBufferPointer { out in
            guard first < last else {
                out.update(repeating: 0)
                return
            }
            let before = 2 * (first - range.lowerBound)
            let after = 2 * (last - range.lowerBound)
            for i in 0..<before { out[i] = 0 }
            for i in after..<count { out[i] = 0 }
            let source = (mapping.base + Self.headerBytes).assumingMemoryBound(to: UInt32.self) + 2 * first
            for i in 0..<(after - before) {
                out[before + i] = Float(bitPattern: UInt32(littleEndian: source[i]))
            }
        }
    }
}

/// What `MusicFile.init(contentsOf:)` throws for a file that is not ours.
public enum MusicFileError: Error, Equatable {
    case notOurs
}

/// A read-only mapping of a whole file, unmapped when the last copy of its `MusicFile` goes.
///
/// Unchecked because the mapped pages are only ever read.
private final class Mapping: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let size: Int

    init(base: UnsafeMutableRawPointer, size: Int) {
        self.base = base
        self.size = size
    }

    deinit {
        munmap(base, size)
    }
}

private extension POSIXError {
    /// The error of `errno` now.
    static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
