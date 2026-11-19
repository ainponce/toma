// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import ProjectFormat

/// The 64 × 36 luma of a frame's crop that `sensitiveScan-1` compares to tell a still frame (design §7.2): a frame
/// whose thumbnail differs less than `reuseThreshold` from the last one recognized reuses what was found in it.
///
/// Each of its pixels is the mean luma of a box of the crop, full range (0 black, 255 white): the Y plane of a
/// biplanar 4:2:0 frame (8 or 10 bits, video range stretched to full), or Rec. 709 luma of a BGRA one. A frame of any
/// other format, or a crop with nothing in it, has no luma and is never still.
///
/// "Differs" is how much its most changed box changed, not how much the whole changed on average: a new e-mail address
/// on a plain screen moves the mean by a few thousandths but the boxes it is in by far more than 1 %, and a frame
/// with new text must be recognized again. Encoding noise on a still screen moves a box's mean by much less.
public struct LumaThumbnail: Equatable, Sendable {
    public static let width = 64
    public static let height = 36
    public static let reuseThreshold = 0.01

    /// `width × height` values, row after row from the top left; empty when the frame could not be read.
    public let luma: [UInt8]

    public init(luma: [UInt8]) {
        self.luma = luma
    }

    /// The thumbnail of `crop` (in fractions of the frame: 0, 0 its top-left corner) of `pixelBuffer`.
    public init(pixelBuffer: CVPixelBuffer, crop: Rect) {
        luma = Self.read(pixelBuffer, crop: crop) ?? []
    }

    /// How much this one differs from `other`: the largest `|a − b| / 255` of their pixels, 0 to 1; 1 when either has no
    /// luma.
    public func difference(from other: LumaThumbnail) -> Double {
        let count = Self.width * Self.height
        guard luma.count == count, other.luma.count == count else { return 1 }
        var largest = 0
        for i in 0..<count {
            largest = max(largest, abs(Int(luma[i]) - Int(other.luma[i])))
        }
        return Double(largest) / 255
    }

    /// Whether what was found in the frame of `recognized` holds for this one: they differ less than `reuseThreshold`.
    /// `recognized` is the thumbnail of the last frame recognized, of the same track and crop, not of the sample before:
    /// a screen that changes a little at each sample is recognized again once the change adds up.
    public func reusesResult(of recognized: LumaThumbnail) -> Bool {
        difference(from: recognized) < Self.reuseThreshold
    }

    // MARK: - Reading

    /// The luma of a format, read from `row`'s byte `x`.
    private enum Layout {
        /// One byte per pixel: the Y plane of 8-bit 4:2:0, video range (16–235) or full.
        case y8(videoRange: Bool)
        /// Two bytes per pixel, the value in the high 10 bits: the Y plane of 10-bit 4:2:0.
        case y16(videoRange: Bool)
        /// Four bytes per pixel, B G R A.
        case bgra

        init?(_ format: OSType) {
            switch format {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: self = .y8(videoRange: true)
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: self = .y8(videoRange: false)
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: self = .y16(videoRange: true)
            case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: self = .y16(videoRange: false)
            case kCVPixelFormatType_32BGRA: self = .bgra
            default: return nil
            }
        }

        var isPlanar: Bool {
            if case .bgra = self { return false }
            return true
        }

        /// The sum of the luma of pixels `[x0, x1)` of `row`, each 0 to 255 in the format's range (stretched later). One
        /// loop per format, so a 4K frame costs a few tens of milliseconds even unoptimized.
        func sum(_ row: UnsafePointer<UInt8>, _ x0: Int, _ x1: Int) -> Int {
            var sum = 0
            var x = x0
            switch self {
            case .y8:
                while x < x1 {
                    sum &+= Int(row[x])
                    x += 1
                }
            case .y16:
                let pixels = UnsafeRawPointer(row)
                while x < x1 {
                    sum &+= Int(UInt16(littleEndian: pixels.loadUnaligned(fromByteOffset: 2 * x, as: UInt16.self)) >> 8)
                    x += 1
                }
            case .bgra:
                var p = row + 4 * x0
                while x < x1 {
                    // Rec. 709 weights in 256ths: B 19, G 183, R 54.
                    sum &+= (19 &* Int(p[0]) &+ 183 &* Int(p[1]) &+ 54 &* Int(p[2]) &+ 128) >> 8
                    p += 4
                    x += 1
                }
            }
            return sum
        }

        var videoRange: Bool {
            switch self {
            case let .y8(videoRange), let .y16(videoRange): return videoRange
            case .bgra: return false
            }
        }
    }

    private static func read(_ buffer: CVPixelBuffer, crop: Rect) -> [UInt8]? {
        guard let layout = Layout(CVPixelBufferGetPixelFormatType(buffer)),
              CVPixelBufferIsPlanar(buffer) == layout.isPlanar,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base: UnsafeMutableRawPointer?
        let (frameWidth, frameHeight, bytesPerRow): (Int, Int, Int)
        if layout.isPlanar {
            base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            (frameWidth, frameHeight, bytesPerRow) = (
                CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0),
                CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        } else {
            base = CVPixelBufferGetBaseAddress(buffer)
            (frameWidth, frameHeight, bytesPerRow) = (
                CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), CVPixelBufferGetBytesPerRow(buffer))
        }
        guard let base, frameWidth > 0, frameHeight > 0,
              let columns = span(crop.x, crop.width, of: frameWidth),
              let rows = span(crop.y, crop.height, of: frameHeight)
        else { return nil }
        let bytes = UnsafePointer<UInt8>(base.assumingMemoryBound(to: UInt8.self))

        // Where each box starts and ends, in pixels: every box has at least one, even in a crop smaller than the thumbnail.
        func edges(_ range: Range<Int>, _ count: Int) -> [Range<Int>] {
            (0..<count).map { i in
                let lower = min(range.lowerBound + i * range.count / count, range.upperBound - 1)
                let upper = max(range.lowerBound + (i + 1) * range.count / count, lower + 1)
                return lower..<upper
            }
        }
        let boxColumns = edges(columns, width)
        let boxRows = edges(rows, height)
        var result = [UInt8](repeating: 0, count: width * height)
        var sums = [Int](repeating: 0, count: width)
        for (j, boxRow) in boxRows.enumerated() {
            for i in 0..<width { sums[i] = 0 }
            for y in boxRow {
                let row = bytes + y * bytesPerRow
                for (i, boxColumn) in boxColumns.enumerated() {
                    sums[i] += layout.sum(row, boxColumn.lowerBound, boxColumn.upperBound)
                }
            }
            for (i, boxColumn) in boxColumns.enumerated() {
                let count = boxColumn.count * boxRow.count
                var mean = (sums[i] + count / 2) / count
                if layout.videoRange { mean = ((mean - 16) * 255 + 109) / 219 }
                result[j * width + i] = UInt8(clamping: mean)
            }
        }
        return result
    }

    /// The pixels `[origin, origin + size)` of a frame `pixels` long cover (fractions of it), within it; `nil` when none.
    /// A crop that is not a number is the whole frame.
    private static func span(_ origin: Double, _ size: Double, of pixels: Int) -> Range<Int>? {
        guard origin.isFinite, size.isFinite else { return 0..<pixels }
        let lower = Int((max(origin, 0) * Double(pixels)).rounded(.down))
        let upper = Int((min(origin + size, 1) * Double(pixels)).rounded(.up))
        let range = min(lower, pixels)..<min(max(upper, 0), pixels)
        return range.isEmpty ? nil : range
    }
}
