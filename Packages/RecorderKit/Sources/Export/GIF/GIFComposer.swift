// SPDX-License-Identifier: GPL-3.0-or-later

/// A GIF frame mapped to its palette (design §7.2, step 4).
public struct QuantizedFrame: Sendable {
    public var width: Int
    public var height: Int
    /// `width × height` indices into `palette.colors`, row by row.
    public var indices: [UInt8]
    public var palette: GIFPalette
    /// Hundredths of a second.
    public var delay: Int

    public init(width: Int, height: Int, indices: [UInt8], palette: GIFPalette, delay: Int) {
        self.width = width
        self.height = height
        self.indices = indices
        self.palette = palette
        self.delay = delay
    }
}

/// What the GIF writes of a frame (design §7.2, step 5): the rectangle of the canvas it changes, its indices row by row
/// into `palette` and, from the second frame on, the transparent index that leaves a pixel as it was shown.
public struct ComposedFrame: Sendable {
    public var x, y, width, height: Int
    /// `width × height` indices, row by row.
    public var indices: [UInt8]
    public var palette: [SIMD3<UInt8>]
    /// `nil` on the first frame; from the second on, `palette.count` (the index every `GIFPalette` leaves free).
    public var transparentIndex: Int?
    /// Hundredths of a second: the frame's own and those of the unchanged frames after it.
    public var delay: Int

    public init(
        x: Int, y: Int, width: Int, height: Int, indices: [UInt8], palette: [SIMD3<UInt8>], transparentIndex: Int? = nil,
        delay: Int
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.indices = indices
        self.palette = palette
        self.transparentIndex = transparentIndex
        self.delay = delay
    }
}

/// What changes from one GIF frame to the next (design §7.2, step 5). It keeps the canvas a viewer shows (disposal 1:
/// every frame stays drawn): from the second frame on, a pixel of the same colour as the canvas becomes the transparent
/// index, and the frame is cropped to the rectangle of the pixels that changed. Colours are compared, not indices, so
/// a frame with a new palette changes only where its colours do. A frame that changes nothing is not written: its
/// delay goes to the frame before. That is why `add` gives back the *previous* frame, once it knows the next one, and
/// `finish` the last.
///
/// A graphic control holds at most `maxDelay`: unchanged time past it goes to a one-pixel transparent frame, so the
/// delays still add up to the duration.
public struct GIFComposer: Sendable {
    /// The longest delay of a GIF frame, in hundredths of a second (16 bits).
    static let maxDelay = 65_535

    private let width: Int
    private let height: Int
    /// The colours shown, `0xRRGGBB` row by row; empty before the first frame.
    private var canvas: [UInt32] = []
    /// The last frame written to the canvas, held until the next one tells how long it stays.
    private var pending: ComposedFrame?
    private var finished = false

    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
    }

    /// Takes the next frame, of the composer's size, with 1...255 colours (the transparent index stays free, plan
    /// decision 16) and every index inside them; gives back the frame before it once it is final, or `nil` (the first
    /// frame, or one that changes nothing).
    public mutating func add(_ frame: QuantizedFrame) -> ComposedFrame? {
        precondition(!finished, "a frame added after finish")
        precondition(frame.width == width && frame.height == height && frame.indices.count == width * height)
        precondition((0...Self.maxDelay).contains(frame.delay))
        let colors = frame.palette.colors
        precondition((1...255).contains(colors.count), "\(colors.count) colours leave no transparent index")
        precondition(Int(frame.indices.max() ?? 0) < colors.count, "an index past the palette")
        var table = [UInt32](repeating: 0, count: 256)
        for (i, color) in colors.enumerated() {
            table[i] = UInt32(color.x) << 16 | UInt32(color.y) << 8 | UInt32(color.z)
        }

        guard let previous = pending else {
            canvas = frame.indices.map { table[Int($0)] }
            pending = ComposedFrame(
                x: 0, y: 0, width: width, height: height, indices: frame.indices, palette: colors, delay: frame.delay)
            return nil
        }
        let transparent = colors.count
        if let changed = Self.draw(frame.indices, table, transparent: UInt8(transparent), on: &canvas, width: width) {
            pending = ComposedFrame(
                x: changed.x, y: changed.y, width: changed.width, height: changed.height, indices: changed.indices,
                palette: colors, transparentIndex: transparent, delay: frame.delay)
            return previous
        }
        if previous.delay + frame.delay <= Self.maxDelay {
            pending?.delay += frame.delay
            return nil
        }
        pending = ComposedFrame(
            x: 0, y: 0, width: 1, height: 1, indices: [1], palette: [.zero], transparentIndex: 1, delay: frame.delay)
        return previous
    }

    /// The last frame, or `nil` if none was added. No frame is added after it.
    public mutating func finish() -> ComposedFrame? {
        finished = true
        canvas = []
        defer { pending = nil }
        return pending
    }

    /// Draws a frame's colours (`table[index]`, `0xRRGGBB`) on `canvas` and gives back the rectangle of the pixels that
    /// changed with its indices, `transparent` where a pixel stayed the same; `nil` if none changed.
    private static func draw(
        _ indices: [UInt8], _ table: [UInt32], transparent: UInt8, on canvas: inout [UInt32], width: Int
    ) -> (x: Int, y: Int, width: Int, height: Int, indices: [UInt8])? {
        let height = indices.count / width
        return indices.withUnsafeBufferPointer { indices in
            table.withUnsafeBufferPointer { table in
                canvas.withUnsafeMutableBufferPointer { canvas in
                    // The smallest rectangle holding every pixel whose colour differs from the canvas.
                    var left = width, right = -1, top = -1, bottom = -1
                    for y in 0..<height {
                        let line = y * width
                        var first = 0
                        while first < width && table[Int(indices[line + first])] == canvas[line + first] { first += 1 }
                        guard first < width else { continue }
                        var last = width - 1
                        while table[Int(indices[line + last])] == canvas[line + last] { last -= 1 }
                        if top < 0 { top = y }
                        bottom = y
                        left = min(left, first)
                        right = max(right, last)
                    }
                    guard top >= 0 else { return nil }
                    let cropWidth = right - left + 1, cropHeight = bottom - top + 1
                    var cropped = [UInt8](repeating: transparent, count: cropWidth * cropHeight)
                    for row in 0..<cropHeight {
                        let line = (top + row) * width + left
                        for column in 0..<cropWidth where table[Int(indices[line + column])] != canvas[line + column] {
                            cropped[row * cropWidth + column] = indices[line + column]
                            canvas[line + column] = table[Int(indices[line + column])]
                        }
                    }
                    return (left, top, cropWidth, cropHeight, cropped)
                }
            }
        }
    }
}
