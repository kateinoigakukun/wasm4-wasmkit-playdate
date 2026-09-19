/// The WASM-4 drawing operations.
///
/// All write into the framebuffer region of the cart's own memory, so none need
/// host state. Colours go through `DRAW_COLORS`: four 4-bit fields, each either
/// selecting a palette entry (1-4) or meaning "skip this pixel" (0).
///
/// A deliberately close translation of the reference `framebuffer.c`, edge
/// cases included: it was verified against that implementation pixel for pixel,
/// and tidying something here is likely to change a boundary pixel.
///
/// Bit order: within a framebuffer byte the *leftmost* pixel is in the *lowest*
/// two bits. Sprites pack the opposite way, and so does the Playdate's screen.
public enum Framebuffer {

    /// Writes a pixel without checking bounds, as the reference does. Callers
    /// are responsible for clipping.
    @inline(__always)
    static func drawPoint(
        _ raw: UnsafeMutableRawBufferPointer, _ colour: UInt8, _ x: Int, _ y: Int
    ) {
        let index = Address.framebuffer + ((Screen.width * y + x) >> 2)
        let shift = UInt8((x & 0x3) << 1)
        let mask = UInt8(0x3) << shift
        raw[index] = (colour << shift) | (raw[index] & ~mask)
    }

    @inline(__always)
    static func drawPointClipped(
        _ raw: UnsafeMutableRawBufferPointer, _ colour: UInt8, _ x: Int, _ y: Int
    ) {
        if x >= 0 && x < Screen.width && y >= 0 && y < Screen.height {
            drawPoint(raw, colour, x, y)
        }
    }

    /// Horizontal run, `endX` exclusive, no clipping.
    static func drawHLine(
        _ raw: UnsafeMutableRawBufferPointer, _ colour: UInt8, _ startX: Int, _ y: Int, _ endX: Int
    ) {
        var startX = startX
        let fillEnd = endX - (endX & 3)
        let fillStart = min((startX + 3) & ~3, fillEnd)

        if fillEnd - fillStart > 3 {
            for x in startX..<fillStart {
                drawPoint(raw, colour, x, y)
            }
            let from = Address.framebuffer + ((Screen.width * y + fillStart) >> 2)
            let to = Address.framebuffer + ((Screen.width * y + fillEnd) >> 2)
            // A byte holding four pixels of one colour is that colour times 0x55.
            let fillByte = colour &* 0x55
            for index in from..<to {
                raw[index] = fillByte
            }
            startX = fillEnd
        }

        for x in startX..<max(startX, endX) {
            drawPoint(raw, colour, x, y)
        }
    }

    static func drawHLineClipped(
        _ raw: UnsafeMutableRawBufferPointer, _ colour: UInt8, _ startX: Int, _ y: Int, _ endX: Int
    ) {
        guard y >= 0, y < Screen.height else { return }
        let start = max(0, startX)
        let end = min(Screen.width, endX)
        guard start < end else { return }
        drawHLine(raw, colour, start, y, end)
    }

    /// The low and high nibbles of the first DRAW_COLORS byte: fill and stroke.
    @inline(__always)
    static func drawColorFields(_ raw: UnsafeMutableRawBufferPointer) -> (UInt8, UInt8) {
        let byte = raw[Address.drawColors]
        return (byte & 0xF, (byte >> 4) & 0xF)
    }

    public static func clear(_ raw: UnsafeMutableRawBufferPointer) {
        for index in 0..<Screen.framebufferSize {
            raw[Address.framebuffer + index] = 0
        }
    }

    public static func hline(
        _ raw: UnsafeMutableRawBufferPointer, x: Int, y: Int, length: Int
    ) {
        let (fill, _) = drawColorFields(raw)
        guard fill != 0 else { return }
        drawHLineClipped(raw, (fill &- 1) & 0x3, x, y, x + length)
    }

    public static func vline(
        _ raw: UnsafeMutableRawBufferPointer, x: Int, y: Int, length: Int
    ) {
        guard y + length > 0, x >= 0, x < Screen.width else { return }
        let (fill, _) = drawColorFields(raw)
        guard fill != 0 else { return }

        let startY = max(0, y)
        let endY = min(Screen.height, y + length)
        let colour = (fill &- 1) & 0x3
        guard startY < endY else { return }
        for row in startY..<endY {
            drawPoint(raw, colour, x, row)
        }
    }

    public static func rect(
        _ raw: UnsafeMutableRawBufferPointer, x: Int, y: Int, width: Int, height: Int
    ) {
        let startX = max(0, x)
        let startY = max(0, y)
        let endXUnclamped = x + width
        let endYUnclamped = y + height
        let endX = max(0, min(endXUnclamped, Screen.width))
        let endY = max(0, min(endYUnclamped, Screen.height))

        let (fill, stroke) = drawColorFields(raw)

        if fill != 0 && startY < endY && startX < endX {
            let colour = (fill &- 1) & 0x3
            for row in startY..<endY {
                drawHLine(raw, colour, startX, row, endX)
            }
        }

        guard stroke != 0 else { return }
        let colour = (stroke &- 1) & 0x3

        if x >= 0 && x < Screen.width && startY < endY {
            for row in startY..<endY {
                drawPoint(raw, colour, x, row)
            }
        }
        if endXUnclamped > 0 && endXUnclamped <= Screen.width && startY < endY {
            for row in startY..<endY {
                drawPoint(raw, colour, endXUnclamped - 1, row)
            }
        }
        if y >= 0 && y < Screen.height && startX < endX {
            drawHLine(raw, colour, startX, y, endX)
        }
        if endYUnclamped > 0 && endYUnclamped <= Screen.height && startX < endX {
            drawHLine(raw, colour, startX, endYUnclamped - 1, endX)
        }
    }

    /// Midpoint ellipse, derived from TIC-80 by way of the reference runtime.
    ///
    /// Long thin ellipses are where this algorithm goes wrong, so the structure
    /// is preserved exactly, including the early return when the stroke field is
    /// 0xF, which looks like a quirk rather than intent but is observable.
    public static func oval(
        _ raw: UnsafeMutableRawBufferPointer, x: Int, y: Int, width: Int, height: Int
    ) {
        let (fill, stroke) = drawColorFields(raw)
        guard stroke != 0xF else { return }

        let strokeColour = (stroke &- 1) & 0x3
        let fillColour = (fill &- 1) & 0x3

        var a = width - 1
        let b = height - 1
        var b1 = b % 2

        var north = y + height / 2
        var west = x
        var east = x + width - 1
        var south = north - b1

        let a2 = a * a
        let b2 = b * b

        var dx = 4 * (1 - a) * b2
        var dy = 4 * (b1 + 1) * a2
        var err = dx + dy + b1 * a2

        a = 8 * a2
        b1 = 8 * b2

        repeat {
            drawPointClipped(raw, strokeColour, east, north)
            drawPointClipped(raw, strokeColour, west, north)
            drawPointClipped(raw, strokeColour, west, south)
            drawPointClipped(raw, strokeColour, east, south)

            let start = west + 1
            let length = east - start
            if fill != 0 && length > 0 {
                drawHLineClipped(raw, fillColour, start, north, east)
                drawHLineClipped(raw, fillColour, start, south, east)
            }

            let err2 = 2 * err
            if err2 <= dy {
                north += 1
                south -= 1
                dy += a
                err += dy
            }
            if err2 >= dx || err2 > dy {
                west += 1
                east -= 1
                dx += b1
                err += dx
            }
        } while west <= east

        // Ensure the poles are filled in for shapes the scan did not reach.
        while north - south < height {
            drawPointClipped(raw, strokeColour, west - 1, north)
            drawPointClipped(raw, strokeColour, east + 1, north)
            north += 1
            drawPointClipped(raw, strokeColour, west - 1, south)
            drawPointClipped(raw, strokeColour, east + 1, south)
            south -= 1
        }
    }

    /// Bresenham, matching the reference's endpoint ordering so that lines are
    /// rasterised identically.
    public static func line(
        _ raw: UnsafeMutableRawBufferPointer, x1: Int, y1: Int, x2: Int, y2: Int
    ) {
        let (fill, _) = drawColorFields(raw)
        guard fill != 0 else { return }
        let colour = (fill &- 1) & 0x3

        var (ax, ay, bx, by) = (x1, y1, x2, y2)
        if by < ay {
            swap(&ax, &bx)
            swap(&ay, &by)
        }

        let deltaX = abs(bx - ax)
        let deltaY = by - ay
        let stepX = ax < bx ? 1 : -1
        var err = (deltaX > deltaY ? deltaX : -deltaY) / 2
        var (x, y) = (ax, ay)

        while true {
            drawPointClipped(raw, colour, x, y)
            if x == bx && y == by { break }
            let current = err
            if current > -deltaX {
                err -= deltaY
                x += stepX
            }
            if current < deltaY {
                err += deltaX
                y += 1
            }
        }
    }

    public struct BlitFlags {
        public static let twoBitsPerPixel = 1
        public static let flipX = 2
        public static let flipY = 4
        public static let rotate = 8
    }

    /// The blitter. Every sprite and character of text goes through here.
    ///
    /// Callers pass the cart's address space rebased at the sprite pointer,
    /// which clamps reads to the 64 KiB window: the reference's bounds check
    /// ignores `srcX`, `srcY` and `stride`. Sprite bits are packed
    /// most-significant-first, the opposite of the framebuffer.
    public static func blit(
        _ raw: UnsafeMutableRawBufferPointer,
        sprite: UnsafeRawBufferPointer,
        dstX: Int, dstY: Int, width: Int, height: Int,
        srcX: Int, srcY: Int, stride: Int, flags: Int
    ) {
        let colours = Bytes.readUInt16(raw, at: Address.drawColors)
        let twoBit = flags & BlitFlags.twoBitsPerPixel != 0
        let rotate = flags & BlitFlags.rotate != 0
        // Rotation is a transpose plus an extra horizontal flip.
        var flipX = flags & BlitFlags.flipX != 0
        let flipY = flags & BlitFlags.flipY != 0

        let clipXMin: Int, clipYMin: Int, clipXMax: Int, clipYMax: Int
        if rotate {
            flipX = !flipX
            clipXMin = max(0, dstY) - dstY
            clipYMin = max(0, dstX) - dstX
            clipXMax = min(width, Screen.height - dstY)
            clipYMax = min(height, Screen.width - dstX)
        } else {
            clipXMin = max(0, dstX) - dstX
            clipYMin = max(0, dstY) - dstY
            clipXMax = min(width, Screen.width - dstX)
            clipYMax = min(height, Screen.height - dstY)
        }
        guard clipXMin < clipXMax, clipYMin < clipYMax else { return }

        // One bit per pixel, no flip, no rotation: what every sprite and every
        // character of text goes through. Taking it separately lifts the
        // colour lookup, the row bases and the branches out of the pixel loop.
        // The general path below stays exactly as the reference has it.
        if !twoBit && !rotate && !flipX && !flipY {
            var mapped = (Int(colours & 0xF) - 1, Int((colours >> 4) & 0xF) - 1)
            if mapped.0 >= 0 { mapped.0 &= 0x3 }
            if mapped.1 >= 0 { mapped.1 &= 0x3 }
            if mapped.0 < 0 && mapped.1 < 0 { return }

            for y in clipYMin..<clipYMax {
                let sourceRow = (srcY + y) * stride + srcX
                let targetRow = Screen.width * (dstY + y) + dstX
                for x in clipXMin..<clipXMax {
                    let bitIndex = sourceRow + x
                    let byteIndex = bitIndex >> 3
                    guard byteIndex >= 0, byteIndex < sprite.count else { continue }
                    let bit = (sprite[byteIndex] >> UInt8(7 - (bitIndex & 0x7))) & 0x1
                    let colour = bit == 0 ? mapped.0 : mapped.1
                    if colour < 0 { continue }

                    let target = targetRow + x
                    let index = Address.framebuffer + (target >> 2)
                    let shift = UInt8((target & 0x3) << 1)
                    raw[index] =
                        (UInt8(colour) << shift) | (raw[index] & ~(UInt8(0x3) << shift))
                }
            }
            return
        }

        for y in clipYMin..<clipYMax {
            for x in clipXMin..<clipXMax {
                let targetX = dstX + (rotate ? y : x)
                let targetY = dstY + (rotate ? x : y)

                let sourceX = srcX + (flipX ? width - x - 1 : x)
                let sourceY = srcY + (flipY ? height - y - 1 : y)

                let bitIndex = sourceY * stride + sourceX
                let colourIndex: Int
                if twoBit {
                    let byteIndex = bitIndex >> 2
                    guard byteIndex >= 0, byteIndex < sprite.count else { continue }
                    let shift = UInt8(6 - ((bitIndex & 0x3) << 1))
                    colourIndex = Int((sprite[byteIndex] >> shift) & 0x3)
                } else {
                    let byteIndex = bitIndex >> 3
                    guard byteIndex >= 0, byteIndex < sprite.count else { continue }
                    let shift = UInt8(7 - (bitIndex & 0x7))
                    colourIndex = Int((sprite[byteIndex] >> shift) & 0x1)
                }

                let field = (colours >> UInt16(colourIndex << 2)) & 0xF
                if field != 0 {
                    drawPoint(raw, UInt8((field &- 1) & 0x3), targetX, targetY)
                }
            }
        }
    }

    /// Draws a string using the built-in font.
    ///
    /// Byte 10 starts a new line; anything below 32 advances one cell without
    /// drawing. `characters` yields code units already read out of memory.
    public static func text<S: Sequence>(
        _ raw: UnsafeMutableRawBufferPointer, characters: S, x: Int, y: Int
    ) where S.Element == UInt16 {
        var currentX = x
        var currentY = y
        font.withUnsafeBytes { glyphs in
            for character in characters {
                if character == 10 {
                    currentY += 8
                    currentX = x
                } else if character >= 32 && character <= 255 {
                    blit(
                        raw, sprite: glyphs,
                        dstX: currentX, dstY: currentY, width: 8, height: 8,
                        srcX: 0, srcY: Int(character - 32) << 3, stride: 8, flags: 0)
                    currentX += 8
                } else {
                    currentX += 8
                }
            }
        }
    }
}
