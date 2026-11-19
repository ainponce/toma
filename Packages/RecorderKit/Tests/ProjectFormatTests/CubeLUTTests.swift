// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import ProjectFormat

// MARK: - Fixtures

/// Each value of an identity `.cube` of `size`³ as `identityCube` writes it, with six decimals, and as `Float` reads it.
private func identityChannel(size: Int) -> (texts: [String], values: [Float]) {
    let texts = (0..<size).map { String(format: "%.6f", Double($0) / Double(size - 1)) }
    return (texts, texts.map { Float($0)! })
}

/// The text of an identity `.cube` of `size`³, red the fastest, with the lines `header` before the table, and
/// `newline` between lines.
private func identityCube(size: Int, header: [String] = [], newline: String = "\n") -> String {
    let channel = identityChannel(size: size).texts
    var lines = header
    lines.append("LUT_3D_SIZE \(size)")
    lines.reserveCapacity(lines.count + size * size * size)
    for b in 0..<size {
        for g in 0..<size {
            for r in 0..<size {
                lines.append(channel[r] + " " + channel[g] + " " + channel[b])
            }
        }
    }
    return lines.joined(separator: newline) + newline
}

/// The values `identityCube(size:)` writes, as `Float` reads its text.
private func identityValues(size: Int) -> [SIMD3<Float>] {
    let channel = identityChannel(size: size).values
    var values: [SIMD3<Float>] = []
    values.reserveCapacity(size * size * size)
    for b in 0..<size {
        for g in 0..<size {
            for r in 0..<size {
                values.append(SIMD3(channel[r], channel[g], channel[b]))
            }
        }
    }
    return values
}

private func parse(_ text: String) throws(CubeLUTError) -> CubeLUT {
    try CubeLUT.parse(Data(text.utf8))
}

/// The error `parse` throws for `text`, or `nil` if it reads.
private func refusal(_ text: String) -> CubeLUTError? {
    refusal(Data(text.utf8))
}

private func refusal(_ data: Data) -> CubeLUTError? {
    do {
        _ = try CubeLUT.parse(data)
        return nil
    } catch {
        return error
    }
}

// MARK: - Reading

@Test func identityCubesAreRead() throws {
    let header = ["# Made by hand", "TITLE \"Identity\"", "", "  # an indented comment", "\t"]
    for size in [2, 33, 65] {
        for newline in ["\n", "\r\n"] {
            let lut = try parse(identityCube(size: size, header: header, newline: newline))
            #expect(lut.size == size)
            #expect(lut.domainMin == SIMD3(0, 0, 0))
            #expect(lut.domainMax == SIMD3(1, 1, 1))
            #expect(lut.values.count == size * size * size)
            #expect(lut.values == identityValues(size: size), "\(size)³ with \(newline == "\n" ? "LF" : "CRLF")")
        }
    }
    // Red is the fastest: the second row is red at its top, the last is white.
    let lut = try parse(identityCube(size: 2))
    #expect(lut.values[1] == SIMD3(1, 0, 0))
    #expect(lut.values[2] == SIMD3(0, 1, 0))
    #expect(lut.values[4] == SIMD3(0, 0, 1))
    #expect(lut.values[7] == SIMD3(1, 1, 1))

    // Tabs and runs of spaces between numbers, a line ending in spaces, a byte-order mark, signs and exponents, a last
    // line without its newline and a lone CR between lines.
    let loose = "\u{FEFF}LUT_3D_SIZE\t2\r0 0 0  \n+1  0\t0\n0 1e0 0\n1 1 0\n0 0 1.\n1 0 1\n0 1 1\n1.0E+0 1 -0.0"
    let read = try parse(loose)
    #expect(read.values.count == 8)
    #expect(read.values[1] == SIMD3(1, 0, 0))
    #expect(read.values[7] == SIMD3(1, 1, 0))

    // Values outside 0…1 are a LUT's own: kept as written.
    let outside = try parse("LUT_3D_SIZE 2\n" + String(repeating: "-0.25 1.5 2\n", count: 8))
    #expect(outside.values.allSatisfy { $0 == SIMD3(-0.25, 1.5, 2) })
    #expect(CubeLUT.sizes == 2...65)
}

@Test func sixtyFiveCubedIsReadAndSixtySixIsNot() throws {
    #expect(try parse(identityCube(size: 65)).size == 65)
    #expect(refusal(identityCube(size: 66)) == .sizeOutOfRange(66))
    #expect(refusal("LUT_3D_SIZE 1\n0 0 0\n") == .sizeOutOfRange(1))
    #expect(refusal("LUT_3D_SIZE 0\n") == .sizeOutOfRange(0))
    #expect(refusal("LUT_3D_SIZE -2\n") == .sizeOutOfRange(-2))
    #expect(refusal("LUT_3D_SIZE 4096\n") == .sizeOutOfRange(4096))
    // Refused before anything is reserved for it.
    #expect(refusal("LUT_3D_SIZE 99999999999\n") == .sizeOutOfRange(99_999_999_999))
    // A size that is not a whole number names its line.
    #expect(refusal("TITLE \"x\"\nLUT_3D_SIZE 33.0\n") == .badNumber(line: 2))
    #expect(refusal("LUT_3D_SIZE\n") == .badNumber(line: 1))
    #expect(refusal("LUT_3D_SIZE 2 2\n") == .badNumber(line: 1))
    #expect(refusal("LUT_3D_SIZE 999999999999999999999999\n") == .badNumber(line: 1))
}

@Test func oneDimensionalIsRefusedWithItsReason() {
    let oneD = "TITLE \"Curve\"\nLUT_1D_SIZE 4\n0 0 0\n0.33 0.33 0.33\n0.66 0.66 0.66\n1 1 1\n"
    #expect(refusal(oneD) == .oneDimensional)
    #expect(refusal("LUT_1D_INPUT_RANGE 0 1\nLUT_3D_SIZE 2\n") == .oneDimensional)
    // A shaper before a 3D table is a 1D part all the same.
    #expect(refusal("LUT_3D_SIZE 2\nLUT_1D_SIZE 2\n") == .oneDimensional)
    // No size: the table cannot be read.
    #expect(refusal("TITLE \"No size\"\n0 0 0\n1 0 0\n") == .missingSize)
    #expect(refusal("") == .missingSize)
    #expect(refusal("# only a comment\n\n") == .missingSize)
    #expect(refusal("TITLE \"x\"\n") == .missingSize)
}

@Test func brokenCubesSayWhy() throws {
    // A row less, or more.
    let full = identityCube(size: 2)
    let lines = full.split(separator: "\n")
    #expect(refusal(lines.dropLast().joined(separator: "\n") + "\n") == .wrongCount(expected: 8, found: 7))
    #expect(refusal(full + "1 1 1\n1 1 1\n") == .wrongCount(expected: 8, found: 10))
    #expect(refusal("LUT_3D_SIZE 2\n") == .wrongCount(expected: 8, found: 0))

    // Not a finite number, or not three of them, names its line.
    let numbered = { (row: String) in "LUT_3D_SIZE 2\n0 0 0\n\(row)\n" + String(repeating: "1 1 1\n", count: 6) }
    for row in ["0.5 nan 1", "0.5 NaN 1", "inf 0 0", "0 -Infinity 0", "1e39 0 0", "0x1p-1 0 0", "0.5 0.5", "0 0 0 0", "0,5 0 0",
                "a b c", "1 1 1 # trailing", "0.5.5 0 0", "- 0 0", "1e 0 0", "1e+ 0 0", ". 0 0"] {
        #expect(refusal(numbered(row)) == .badNumber(line: 3), "\(row)")
    }
    #expect(refusal("LUT_3D_SIZE 2\r\n0 0 0\r\n0 0\r\n") == .badNumber(line: 3))
    // A word in capitals where the table starts is a row, not another tool's keyword.
    #expect(refusal("LUT_3D_SIZE 2\nNAN 0 0\n") == .badNumber(line: 2))
    #expect(refusal("LUT_3D_SIZE 2\nINF 0 0\n") == .badNumber(line: 2))
    // Text that is not a `.cube` has no size before its first row.
    #expect(refusal("Hello, world.\nLUT_3D_SIZE 2\n") == .missingSize)
    #expect(refusal("lut_3d_size 2\n") == .missingSize)

    // Keywords: their numbers, twice, or among the table.
    #expect(refusal("DOMAIN_MIN 0 0\nLUT_3D_SIZE 2\n") == .badNumber(line: 1))
    #expect(refusal("DOMAIN_MAX 1 1 nan\nLUT_3D_SIZE 2\n") == .badNumber(line: 1))
    #expect(refusal("LUT_3D_SIZE 2\nLUT_3D_SIZE 2\n") == .badNumber(line: 2))
    #expect(refusal("DOMAIN_MIN 0 0 0\nDOMAIN_MIN 0 0 0\nLUT_3D_SIZE 2\n") == .badNumber(line: 2))
    #expect(refusal("LUT_3D_SIZE 2\n0 0 0\nTITLE \"late\"\n") == .badNumber(line: 3))
    #expect(refusal("LUT_3D_SIZE 2\n0 0 0\nLUT_3D_SIZE 2\n") == .badNumber(line: 3))

    // A domain whose start is not below its end.
    let table = String(repeating: "0 0 0\n", count: 8)
    #expect(refusal("DOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 0 1\nLUT_3D_SIZE 2\n" + table) == .badDomain)
    #expect(refusal("DOMAIN_MIN 0 0 0.5\nDOMAIN_MAX 1 1 0.25\nLUT_3D_SIZE 2\n" + table) == .badDomain)
    #expect(refusal("DOMAIN_MIN 2 2 2\nLUT_3D_SIZE 2\n" + table) == .badDomain)
    #expect(refusal("LUT_3D_INPUT_RANGE 1 1\nLUT_3D_SIZE 2\n" + table) == .badDomain)

    // Not text: bytes that are not UTF-8, a NUL or another control character.
    #expect(refusal(Data([0x4C, 0x55, 0x54, 0xFF, 0xFE, 0x0A])) == .notText)
    #expect(refusal(Data("LUT_3D_SIZE 2\n\u{0}0 0 0\n".utf8)) == .notText)
    #expect(refusal(Data("LUT_3D_SIZE 2\n\u{1B}[0m\n".utf8)) == .notText)
    // A PNG picked by mistake.
    #expect(refusal(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])) == .notText)

    // Larger than a `.cube` is read, whatever it holds; the limit itself is read.
    #expect(CubeLUT.maxBytes == 16_777_216)
    #expect(refusal(Data(count: CubeLUT.maxBytes + 1)) == .tooLarge)
    let padded = Data((full + String(repeating: "#", count: CubeLUT.maxBytes - full.utf8.count)).utf8)
    #expect(padded.count == CubeLUT.maxBytes)
    #expect(try CubeLUT.parse(padded).size == 2)
}

@Test func domainIsKept() throws {
    let table = String(repeating: "0.5 0.5 0.5\n", count: 8)
    let lut = try parse("DOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\nLUT_3D_SIZE 2\n" + table)
    #expect(lut.domainMin == SIMD3(0, 0, 0))
    #expect(lut.domainMax == SIMD3(2, 2, 2))
    // Each channel its own, before or after the size.
    let mixed = try parse("LUT_3D_SIZE 2\nDOMAIN_MAX 1 4 2\nDOMAIN_MIN -0.5 0 0.25\n" + table)
    #expect(mixed.domainMin == SIMD3(-0.5, 0, 0.25))
    #expect(mixed.domainMax == SIMD3(1, 4, 2))
    // Resolve's one range for the three channels.
    let range = try parse("LUT_3D_INPUT_RANGE 0 1.5\nLUT_3D_SIZE 2\n" + table)
    #expect(range.domainMin == SIMD3(0, 0, 0))
    #expect(range.domainMax == SIMD3(1.5, 1.5, 1.5))
    #expect(refusal("LUT_3D_INPUT_RANGE 0 1\nDOMAIN_MAX 1 1 1\nLUT_3D_SIZE 2\n" + table) == .badNumber(line: 2))
    // A keyword of another tool before the table is passed over.
    #expect(try parse("LUT_IN_VIDEO_RANGE\nLUT_3D_SIZE 2\n" + table).values.count == 8)
}
