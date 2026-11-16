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

        func expand(_ code: Int) -> [UInt8] {
            var reversed = [UInt8]()
            var c = code
            while c >= clear + 2 {
                reversed.append(suffix[c])
                c = prefix[c]
            }
            reversed.append(UInt8(c))
            return reversed.reversed()
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
            let entry: [UInt8]
            if code < next {
                entry = expand(code)
            } else if code == next {
                var e = expand(previous)
                e.append(e[0])
                entry = e
            } else {
                return nil
            }
            out += entry
            if next < 4096 {
                prefix[next] = previous
                suffix[next] = entry[0]
                next += 1
                if next == (1 << size) && size < 12 { size += 1 }
            }
            previous = code
        }
    }
}
