// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct GIFImageBlock: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var palette: [SIMD3<UInt8>]
    public var transparentIndex: Int?
    /// Hundredths of a second.
    public var delay: Int
    public var minimumCodeSize: Int
    /// LZW data from `LZWEncoder.encode` (not yet split into sub-blocks).
    public var data: [UInt8]

    public init(
        x: Int, y: Int, width: Int, height: Int, palette: [SIMD3<UInt8>], transparentIndex: Int? = nil,
        delay: Int, minimumCodeSize: Int, data: [UInt8]
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.palette = palette
        self.transparentIndex = transparentIndex
        self.delay = delay
        self.minimumCodeSize = minimumCodeSize
        self.data = data
    }
}

public enum GIFWriterError: Error, Equatable {
    case invalidSize
    case invalidBlock(String)
    case writeFailed(errno: Int32)
    case finished
}

public enum GIFDelays {
    /// `d_n = round((n+1)·100/fps) − round(n·100/fps)`, accumulated so it never drifts.
    public static func delays(frameCount: Int, fps: Int) -> [Int] {
        guard frameCount > 0, fps > 0 else { return [] }
        func rounded(_ n: Int) -> Int { (n * 100 + fps / 2) / fps }
        return (0..<frameCount).map { rounded($0 + 1) - rounded($0) }
    }
}

/// GIF89a writer: no global table, one local table per image block.
public struct GIFWriter {
    private let fileDescriptor: Int32
    private let width: Int
    private let height: Int
    private var finished = false

    public init(fileDescriptor: Int32, width: Int, height: Int, loops: Bool) throws {
        guard (1...65535).contains(width), (1...65535).contains(height) else { throw GIFWriterError.invalidSize }
        self.fileDescriptor = fileDescriptor
        self.width = width
        self.height = height
        var header = [UInt8]("GIF89a".utf8)
        Self.appendLE16(&header, width)
        Self.appendLE16(&header, height)
        header += [0x70, 0, 0]  // no global table, 8-bit color resolution, background 0, no aspect
        if loops {
            header += [0x21, 0xFF, 0x0B] + [UInt8]("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]
        }
        try Self.writeAll(fileDescriptor, header)
    }

    public mutating func write(_ block: GIFImageBlock) throws {
        guard !finished else { throw GIFWriterError.finished }
        guard block.width > 0, block.height > 0, block.x >= 0, block.y >= 0,
            block.x + block.width <= width, block.y + block.height <= height
        else { throw GIFWriterError.invalidBlock("rectangle outside the screen") }
        guard (1...256).contains(block.palette.count) else { throw GIFWriterError.invalidBlock("palette size") }
        guard (2...8).contains(block.minimumCodeSize) else { throw GIFWriterError.invalidBlock("minimum code size") }
        guard (0...65535).contains(block.delay) else { throw GIFWriterError.invalidBlock("delay") }
        if let t = block.transparentIndex, !(0..<block.palette.count).contains(t) {
            throw GIFWriterError.invalidBlock("transparent index")
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(block.data.count + block.data.count / 255 + 800)
        // Graphic control: disposal 1 (do not dispose), delay, transparent index.
        let packed: UInt8 = (1 << 2) | (block.transparentIndex != nil ? 1 : 0)
        bytes += [0x21, 0xF9, 0x04, packed]
        Self.appendLE16(&bytes, block.delay)
        bytes += [UInt8(block.transparentIndex ?? 0), 0x00]
        // Image descriptor with a local table padded to a power of two (>= 2).
        var tableBits = 1
        while (1 << tableBits) < block.palette.count { tableBits += 1 }
        bytes.append(0x2C)
        Self.appendLE16(&bytes, block.x)
        Self.appendLE16(&bytes, block.y)
        Self.appendLE16(&bytes, block.width)
        Self.appendLE16(&bytes, block.height)
        bytes.append(0x80 | UInt8(tableBits - 1))
        for color in block.palette { bytes += [color.x, color.y, color.z] }
        for _ in block.palette.count..<(1 << tableBits) { bytes += [0, 0, 0] }
        bytes.append(UInt8(block.minimumCodeSize))
        var offset = 0
        while offset < block.data.count {
            let n = min(255, block.data.count - offset)
            bytes.append(UInt8(n))
            bytes += block.data[offset..<(offset + n)]
            offset += n
        }
        bytes.append(0x00)
        try Self.writeAll(fileDescriptor, bytes)
    }

    public mutating func finish() throws {
        guard !finished else { throw GIFWriterError.finished }
        finished = true
        try Self.writeAll(fileDescriptor, [0x3B])
    }

    private static func appendLE16(_ bytes: inout [UInt8], _ value: Int) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = Foundation.write(fd, raw.baseAddress! + done, raw.count - done)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw GIFWriterError.writeFailed(errno: errno)
                }
                done += n
            }
        }
    }
}
