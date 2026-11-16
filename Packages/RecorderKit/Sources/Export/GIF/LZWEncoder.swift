// SPDX-License-Identifier: GPL-3.0-or-later

/// The variable-width LZW of GIF89a: LSB-first codes, `clear` when the table
/// reaches 4096 entries, `end` closing the stream.
public enum LZWEncoder {
    /// `max(2, ⌈log₂ colors⌉)`.
    public static func minimumCodeSize(colors: Int) -> Int {
        var size = 2
        while (1 << size) < colors && size < 8 { size += 1 }
        return size
    }

    public static func encode(_ indices: UnsafeBufferPointer<UInt8>, minimumCodeSize: Int) -> [UInt8] {
        precondition((2...8).contains(minimumCodeSize), "GIF minimum code size is 2...8")
        let clearCode = 1 << minimumCodeSize
        let endCode = clearCode + 1
        let firstFree = clearCode + 2
        let maxCodes = 4096
        let tableSize = 8192  // open addressing, load <= 0.5

        var out = [UInt8]()
        out.reserveCapacity(indices.count / 2 + 16)
        var bitBuffer: UInt32 = 0
        var bitCount = 0
        var size = minimumCodeSize + 1
        var nextCode = firstFree

        var keys = [Int32](repeating: -1, count: tableSize)
        var values = [UInt16](repeating: 0, count: tableSize)

        func emit(_ code: Int) {
            bitBuffer |= UInt32(code) << UInt32(bitCount)
            bitCount += size
            while bitCount >= 8 {
                out.append(UInt8(truncatingIfNeeded: bitBuffer))
                bitBuffer >>= 8
                bitCount -= 8
            }
        }
        func resetTable() {
            for i in 0..<tableSize { keys[i] = -1 }
            nextCode = firstFree
            size = minimumCodeSize + 1
        }
        /// Mirrors what the decoder does after reading a code: one more entry,
        /// and one more bit when its next code reaches a power of two.
        func grow() {
            if nextCode > (1 << size) && size < 12 { size += 1 }
        }

        emit(clearCode)
        if indices.count > 0 {
            var prefix = Int(indices[0])
            for i in 1..<indices.count {
                let byte = Int(indices[i])
                let key = Int32(prefix << 8 | byte)
                var slot = Int((UInt32(bitPattern: key) &* 2654435761) >> 19) & (tableSize - 1)
                var found = -1
                while keys[slot] != -1 {
                    if keys[slot] == key {
                        found = Int(values[slot])
                        break
                    }
                    slot = (slot + 1) & (tableSize - 1)
                }
                if found >= 0 {
                    prefix = found
                    continue
                }
                emit(prefix)
                if nextCode == maxCodes {
                    emit(clearCode)
                    resetTable()
                } else {
                    keys[slot] = key
                    values[slot] = UInt16(nextCode)
                    nextCode += 1
                    grow()
                }
                prefix = byte
            }
            emit(prefix)
            if nextCode < maxCodes {
                nextCode += 1
                grow()
            }
        }
        emit(endCode)
        if bitCount > 0 { out.append(UInt8(truncatingIfNeeded: bitBuffer)) }
        return out
    }
}
