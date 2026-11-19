// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why a file is not a `.cube` Toma reads (phase 2 design §6.3): each its own reason, for the user.
public enum CubeLUTError: Error, Equatable, Sendable {
    /// Not UTF-8 text, or text with a control character other than a tab, a line feed or a carriage return (a NUL, an
    /// escape): an image or a binary file picked by mistake.
    case notText
    /// A 1D LUT (`LUT_1D_SIZE` or `LUT_1D_INPUT_RANGE`), alone or as a shaper before a 3D table: only 3D ones are read.
    case oneDimensional
    /// No `LUT_3D_SIZE` before the first row of the table, or none at all.
    case missingSize
    /// A `LUT_3D_SIZE` outside `CubeLUT.sizes`, refused before anything is reserved for it.
    case sizeOutOfRange(Int)
    /// The table does not have `size³` rows (`expected`): `found` is how many it has.
    case wrongCount(expected: Int, found: Int)
    /// The line, counted from 1, is not one a `.cube` has: a number that is not a finite decimal (`nan`, `inf`, hex,
    /// `0,5`, one that overflows a `Float`), the wrong count of numbers for its keyword or row, a size that is not a
    /// whole number, a keyword given twice (the domain is `DOMAIN_MIN`, `DOMAIN_MAX` or `LUT_3D_INPUT_RANGE`, once), or a
    /// keyword among the table's rows.
    case badNumber(line: Int)
    /// A domain whose start is not below its end, in some channel.
    case badDomain
    /// Larger than `CubeLUT.maxBytes`, whatever it holds.
    case tooLarge
}

/// A 3D LUT read from a `.cube` (the Adobe/Iridas text format; phase 2 design §6.3): the camera's colors of
/// `CameraColorPreset.custom`, and the table of each code-made look (`CameraLooks`).
public struct CubeLUT: Equatable, Sendable {
    /// The points on each side of the cube, in `sizes`.
    public var size: Int
    /// The input that maps to the cube's first point, per channel (`DOMAIN_MIN`; `0 0 0` when the file has none).
    public var domainMin: SIMD3<Float>
    /// The input that maps to the cube's last point, per channel (`DOMAIN_MAX`; `1 1 1` when the file has none).
    public var domainMax: SIMD3<Float>
    /// The `size³` outputs, red the fastest, then green, then blue, as a `.cube` lists them: the point `(r, g, b)` is at
    /// `r + size × (g + size × b)`. Finite, and kept as written, outside 0…1 too.
    public var values: [SIMD3<Float>]

    /// The sizes read: 2 to 65 points a side.
    public static let sizes = 2...65
    /// The largest `.cube` read, 16 MiB (`PackageFileKind.lut.maxBytes`): a 65³ table with eight decimals a number is
    /// about half of it.
    public static let maxBytes = 16_777_216

    public init(size: Int, domainMin: SIMD3<Float>, domainMax: SIMD3<Float>, values: [SIMD3<Float>]) {
        self.size = size
        self.domainMin = domainMin
        self.domainMax = domainMax
        self.values = values
    }

    /// The 3D LUT of `data`, the bytes of a `.cube`, read strictly.
    ///
    /// UTF-8 text (a byte-order mark is passed over) with lines ended by LF, CRLF or CR. Empty lines, lines of spaces and
    /// tabs, and lines that start with `#` are passed over; numbers are separated by spaces or tabs. Before the table:
    /// `TITLE` (anything after it), `LUT_3D_SIZE n` (once), `DOMAIN_MIN r g b` and `DOMAIN_MAX r g b` (once each) or
    /// Resolve's `LUT_3D_INPUT_RANGE min max` (the same domain for the three channels, instead of those two), and a
    /// keyword of another tool (capitals, digits and `_`, with at least one `_`, such as `LUT_IN_VIDEO_RANGE`), passed
    /// over. Then exactly `n³` rows of three finite decimals (`[+-]digits[.digits][e[+-]digits]`, at most 64 characters).
    /// Anything else is refused with its `CubeLUTError`; nothing more than `n³` values is ever reserved.
    public static func parse(_ data: Data) throws(CubeLUTError) -> CubeLUT {
        guard data.count <= maxBytes else { throw .tooLarge }
        let result = data.withUnsafeBytes { bytes in
            var parser = CubeParser(bytes: bytes)
            return Result { () throws(CubeLUTError) in try parser.parse() }
        }
        return try result.get()
    }
}

/// The reading of `CubeLUT.parse`, over the file's bytes.
private struct CubeParser {
    let bytes: UnsafeRawBufferPointer

    var size: Int?
    var domainMin: SIMD3<Float>?
    var domainMax: SIMD3<Float>?
    var values: [SIMD3<Float>] = []
    /// The rows of the table so far, the ones past `size³` counted and not kept.
    var rows = 0

    init(bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    mutating func parse() throws(CubeLUTError) -> CubeLUT {
        try checkText()
        var start = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var line = 0
        while start < bytes.count {
            line += 1
            var end = start
            while end < bytes.count, bytes[end] != Byte.lineFeed, bytes[end] != Byte.carriageReturn { end += 1 }
            try read(start..<end, line: line)
            start = end + (bytes[safe: end] == Byte.carriageReturn && bytes[safe: end + 1] == Byte.lineFeed ? 2 : 1)
        }
        guard let size else { throw .missingSize }
        let expected = size * size * size
        guard rows == expected else { throw .wrongCount(expected: expected, found: rows) }
        let low = domainMin ?? SIMD3(repeating: 0), high = domainMax ?? SIMD3(repeating: 1)
        guard all(low .< high) else { throw .badDomain }
        return CubeLUT(size: size, domainMin: low, domainMax: high, values: values)
    }

    // MARK: - Lines

    /// One line, without its end.
    private mutating func read(_ range: Range<Int>, line: Int) throws(CubeLUTError) {
        // At most five tokens are kept: no line of a `.cube` has more than four.
        var tokens: [Range<Int>] = []
        var count = 0
        var index = range.lowerBound
        while index < range.upperBound {
            while index < range.upperBound, Byte.isBlank(bytes[index]) { index += 1 }
            guard index < range.upperBound else { break }
            let tokenStart = index
            while index < range.upperBound, !Byte.isBlank(bytes[index]) { index += 1 }
            if count == 0, bytes[tokenStart] == Byte.hash { return }
            count += 1
            if tokens.count < 5 { tokens.append(tokenStart..<index) }
        }
        guard let first = tokens.first else { return }
        let tableStarted = rows > 0
        let name = keyword(first)

        switch name {
        case "TITLE":
            guard !tableStarted else { throw .badNumber(line: line) }
        case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE":
            throw .oneDimensional
        case "LUT_3D_SIZE":
            guard !tableStarted, size == nil, count == 2, let n = integer(tokens[1]) else { throw .badNumber(line: line) }
            guard CubeLUT.sizes.contains(n) else { throw .sizeOutOfRange(n) }
            size = n
            values.reserveCapacity(n * n * n)
        case "DOMAIN_MIN", "DOMAIN_MAX":
            let isMin = name == "DOMAIN_MIN"
            guard !tableStarted, (isMin ? domainMin : domainMax) == nil, count == 4,
                  let r = number(tokens[1]), let g = number(tokens[2]), let b = number(tokens[3])
            else { throw .badNumber(line: line) }
            if isMin { domainMin = SIMD3(r, g, b) } else { domainMax = SIMD3(r, g, b) }
        case "LUT_3D_INPUT_RANGE":
            guard !tableStarted, domainMin == nil, domainMax == nil, count == 3,
                  let low = number(tokens[1]), let high = number(tokens[2])
            else { throw .badNumber(line: line) }
            domainMin = SIMD3(repeating: low)
            domainMax = SIMD3(repeating: high)
        case .some:
            // Another tool's keyword: passed over before the table, never among its rows.
            guard !tableStarted else { throw .badNumber(line: line) }
        case nil:
            guard let size else { throw .missingSize }
            guard count == 3, let r = number(tokens[0]), let g = number(tokens[1]), let b = number(tokens[2])
            else { throw .badNumber(line: line) }
            rows += 1
            if rows <= size * size * size { values.append(SIMD3(r, g, b)) }
        }
    }

    /// The keyword `token` is, if it is one: a known one, or capitals, digits and `_` starting with a capital and with
    /// at least one `_` (so a row that starts with `NAN` is a row, refused as one).
    private func keyword(_ token: Range<Int>) -> String? {
        let first = bytes[token.lowerBound]
        guard Byte.isCapital(first), token.count <= 64 else { return nil }
        var underscore = false
        for index in token {
            let byte = bytes[index]
            if byte == Byte.underscore {
                underscore = true
            } else if !Byte.isCapital(byte), !Byte.isDigit(byte) {
                return nil
            }
        }
        let text = string(token)
        return underscore || text == "TITLE" ? text : nil
    }

    // MARK: - Numbers

    /// The finite `Float` of `token` if it is a decimal: `[+-]digits[.digits][e[+-]digits]` or `[+-].digits[…]`, at most
    /// 64 characters. Never `nan`, `inf`, hex or a number with a comma, which `Float(_:)` alone would take or refuse
    /// differently.
    private func number(_ token: Range<Int>) -> Float? {
        guard token.count <= 64 else { return nil }
        var index = token.lowerBound
        let end = token.upperBound
        if index < end, bytes[index] == Byte.plus || bytes[index] == Byte.minus { index += 1 }
        var digits = 0
        while index < end, Byte.isDigit(bytes[index]) {
            index += 1
            digits += 1
        }
        if index < end, bytes[index] == Byte.point {
            index += 1
            while index < end, Byte.isDigit(bytes[index]) {
                index += 1
                digits += 1
            }
        }
        guard digits > 0 else { return nil }
        if index < end, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < end, bytes[index] == Byte.plus || bytes[index] == Byte.minus { index += 1 }
            var exponent = 0
            while index < end, Byte.isDigit(bytes[index]) {
                index += 1
                exponent += 1
            }
            guard exponent > 0 else { return nil }
        }
        guard index == end, let value = Float(string(token)), value.isFinite else { return nil }
        return value
    }

    /// The `Int` of `token` if it is `[+-]digits` and fits.
    private func integer(_ token: Range<Int>) -> Int? {
        guard token.count <= 64 else { return nil }
        var index = token.lowerBound
        if bytes[index] == Byte.plus || bytes[index] == Byte.minus { index += 1 }
        guard index < token.upperBound, (index..<token.upperBound).allSatisfy({ Byte.isDigit(bytes[$0]) }) else { return nil }
        return Int(string(token))
    }

    private func string(_ token: Range<Int>) -> String {
        String(decoding: UnsafeRawBufferPointer(rebasing: bytes[token]), as: UTF8.self)
    }

    // MARK: - Text

    /// Throws `notText` unless the bytes are UTF-8 without a control character other than tab, LF and CR.
    private func checkText() throws(CubeLUTError) {
        var ascii = true
        for byte in bytes {
            if byte < 0x20, byte != Byte.tab, byte != Byte.lineFeed, byte != Byte.carriageReturn { throw .notText }
            if byte == 0x7F { throw .notText }
            if byte >= 0x80 { ascii = false }
        }
        guard ascii || String(validating: bytes, as: UTF8.self) != nil else { throw .notText }
    }
}

/// The bytes the parser looks for.
private enum Byte {
    static let tab = UInt8(ascii: "\t")
    static let lineFeed = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let hash = UInt8(ascii: "#")
    static let plus = UInt8(ascii: "+")
    static let minus = UInt8(ascii: "-")
    static let point = UInt8(ascii: ".")
    static let underscore = UInt8(ascii: "_")

    static func isBlank(_ byte: UInt8) -> Bool { byte == space || byte == tab }
    static func isDigit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }
    static func isCapital(_ byte: UInt8) -> Bool { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) }
}

extension UnsafeRawBufferPointer {
    /// The byte at `index`, or `nil` past the end.
    fileprivate subscript(safe index: Int) -> UInt8? {
        index < count ? self[index] : nil
    }
}
