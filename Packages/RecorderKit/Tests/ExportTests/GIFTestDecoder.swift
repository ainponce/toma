// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Our own GIF LZW decoder, only to check what `LZWEncoder` wrote.
enum GIFTestDecoder {
    /// The canvas after each image of a GIF, as a viewer shows it, with the image's delay in hundredths of a second:
    /// every image is drawn over the canvas left by the one before (disposal 1, "do not dispose"), and its pixels at
    /// the transparent index of its graphic control leave the canvas as it was. The canvas starts black, row by row,
    /// the logical screen's size. An empty array if `data` is not a GIF this reads: an image outside the screen, an
    /// interlaced one, a disposal other than 0 or 1, an index past the color table, LZW that does not decode to the
    /// image's pixels or data that ends before the trailer.
    static func frames(_ data: Data) -> [(canvas: [SIMD3<UInt8>], delay: Int)] {
        let bytes = [UInt8](data)
        var position = 0
        func byte() -> Int? {
            guard position < bytes.count else { return nil }
            position += 1
            return Int(bytes[position - 1])
        }
        func le16() -> Int? {
            guard let low = byte(), let high = byte() else { return nil }
            return low | high << 8
        }
        func colorTable(_ packed: Int) -> [SIMD3<UInt8>]? {
            let count = 1 << ((packed & 7) + 1)
            guard position + count * 3 <= bytes.count else { return nil }
            defer { position += count * 3 }
            return (0..<count).map { i in
                SIMD3(bytes[position + i * 3], bytes[position + i * 3 + 1], bytes[position + i * 3 + 2])
            }
        }
        func subBlocks() -> [UInt8]? {
            var out = [UInt8]()
            while let size = byte() {
                if size == 0 { return out }
                guard position + size <= bytes.count else { return nil }
                out += bytes[position..<(position + size)]
                position += size
            }
            return nil
        }

        guard bytes.count >= 13, bytes.prefix(6).elementsEqual("GIF89a".utf8) || bytes.prefix(6).elementsEqual("GIF87a".utf8)
        else { return [] }
        position = 6
        guard let width = le16(), let height = le16(), let screenPacked = byte(), byte() != nil, byte() != nil else { return [] }
        var global: [SIMD3<UInt8>]?
        if screenPacked & 0x80 != 0 {
            guard let table = colorTable(screenPacked) else { return [] }
            global = table
        }
        var canvas = [SIMD3<UInt8>](repeating: .zero, count: width * height)
        var frames: [(canvas: [SIMD3<UInt8>], delay: Int)] = []
        var delay = 0
        var transparent: Int?
        while let introducer = byte() {
            switch introducer {
            case 0x3B:
                return frames
            case 0x21:
                guard let label = byte() else { return [] }
                if label == 0xF9 {
                    guard byte() == 4, let packed = byte(), let d = le16(), let t = byte(), byte() == 0 else { return [] }
                    guard (packed >> 2) & 7 <= 1 else { return [] }
                    delay = d
                    transparent = packed & 1 != 0 ? t : nil
                } else {
                    guard subBlocks() != nil else { return [] }
                }
            case 0x2C:
                guard let x = le16(), let y = le16(), let w = le16(), let h = le16(), let packed = byte() else { return [] }
                guard w > 0, h > 0, x + w <= width, y + h <= height, packed & 0x40 == 0 else { return [] }
                var table = global
                if packed & 0x80 != 0 {
                    guard let local = colorTable(packed) else { return [] }
                    table = local
                }
                guard let table, let minimumCodeSize = byte(), (2...8).contains(minimumCodeSize),
                    let data = subBlocks(), let indices = lzw(data, minimumCodeSize: minimumCodeSize),
                    indices.count == w * h
                else { return [] }
                for row in 0..<h {
                    for column in 0..<w {
                        let index = Int(indices[row * w + column])
                        if index == transparent { continue }
                        guard index < table.count else { return [] }
                        canvas[(y + row) * width + x + column] = table[index]
                    }
                }
                frames.append((canvas, delay))
                delay = 0
                transparent = nil
            default:
                return []
            }
        }
        return []
    }

    static func lzw(_ data: [UInt8], minimumCodeSize: Int) -> [UInt8]? {
        let clear = 1 << minimumCodeSize
        let end = clear + 1
        var size = minimumCodeSize + 1
        var next = end + 1
        var prefix = [Int](repeating: 0, count: 4096)
        var suffix = [UInt8](repeating: 0, count: 4096)
        var out = [UInt8]()
        var previous = -1
        var bits: UInt32 = 0
        var bitCount = 0
        var position = 0

        /// Appends the string of `code` to `out` (walking the chain backwards, then reversing in place).
        func append(_ code: Int) {
            let start = out.count
            var c = code
            while c >= clear + 2 {
                out.append(suffix[c])
                c = prefix[c]
            }
            out.append(UInt8(c))
            out[start...].reverse()
        }

        while true {
            while bitCount < size {
                guard position < data.count else { return nil }
                bits |= UInt32(data[position]) << UInt32(bitCount)
                position += 1
                bitCount += 8
            }
            let code = Int(bits & UInt32((1 << size) - 1))
            bits >>= UInt32(size)
            bitCount -= size
            if code == clear {
                size = minimumCodeSize + 1
                next = end + 1
                previous = -1
                continue
            }
            if code == end { return out }
            if previous == -1 {
                guard code < clear else { return nil }
                out.append(UInt8(code))
                previous = code
                continue
            }
            let start = out.count
            if code < next {
                append(code)
            } else if code == next {
                append(previous)
                out.append(out[start])
            } else {
                return nil
            }
            if next < 4096 {
                prefix[next] = previous
                suffix[next] = out[start]
                next += 1
                if next == (1 << size) && size < 12 { size += 1 }
            }
            previous = code
        }
    }
}
