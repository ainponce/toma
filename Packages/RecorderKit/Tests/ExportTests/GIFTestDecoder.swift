// SPDX-License-Identifier: GPL-3.0-or-later

/// Our own GIF LZW decoder, only to check what `LZWEncoder` wrote.
enum GIFTestDecoder {
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
