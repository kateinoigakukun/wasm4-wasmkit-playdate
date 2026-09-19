import CPlaydate
import WASM4

/// Converts the console's 160x160 four-colour picture onto the 400x240
/// black-and-white screen, centred at 1:1.
///
/// Bit orders are opposite: leftmost pixel is the lowest bits on the console,
/// the 0x80 bit on the Playdate.
struct Display {
    static let originX = (400 - Screen.width) / 2
    static let originY = (240 - Screen.height) / 2

    var ditherPolicy: Dither.Policy = .threshold

    /// Forces the next frame to be converted in full.
    mutating func invalidate() {
        for index in previous.indices { previous[index] = 0xFF }
        sinceFullFrame = 0
    }

    /// Frames since the whole picture was last converted and marked.
    ///
    /// Skipping unchanged rows is invisible on the device, whose panel holds
    /// what it was last sent, but anything watching over USB -- Mirror, or a
    /// screenshot -- only receives the rows marked dirty and would otherwise
    /// assemble a picture full of holes. A full frame twice a second costs
    /// almost nothing and keeps those honest.
    private var sinceFullFrame = 0
    private static let fullFrameInterval = 30

    private var cachedPalette: (UInt32, UInt32, UInt32, UInt32) = (1, 1, 1, 1)
    private var cachedPolicy: Dither.Policy = .stretched
    private var cachedCounts = [-1, -1, -1, -1]
    private var shades: [UInt8] = [0, 0, 0, 0]

    /// Which colours the previous frame used, tallied during the conversion pass
    /// so it costs nothing per pixel. One frame of lag, which is not visible.
    private var colourCounts = [0, 0, 0, 0]

    /// The console picture as it was last converted, a row at a time.
    ///
    /// Comparing forty bytes is far cheaper than converting a hundred and sixty
    /// pixels, and a game changes only the part of the screen it animates: the
    /// Playdate keeps what is already on the panel, so an unchanged row needs
    /// neither conversion nor a refresh.
    private var previous = [UInt8](repeating: 0xFF, count: Screen.framebufferSize)

    /// Recomputes the per-colour dither levels, and only when something that
    /// feeds them has changed -- for most carts that is once.
    private mutating func updateShades(for palette: (UInt32, UInt32, UInt32, UInt32)) {
        guard palette != cachedPalette || ditherPolicy != cachedPolicy
            || colourCounts != cachedCounts
        else {
            return
        }
        cachedPalette = palette
        cachedPolicy = ditherPolicy
        cachedCounts = colourCounts
        shades = Dither.levels(palette: palette, policy: ditherPolicy, coverage: colourCounts)
        // The levels decide what each colour becomes, so when they move every
        // row has to be converted again even where the cart changed nothing:
        // the same bytes now mean different pixels. Carts recolour to flash and
        // fade, so this is not a rare path.
        invalidate()
    }

    /// Converts one frame.
    ///
    /// A destination byte is assembled in a register and stored once. Both
    /// origins are multiples of eight, so eight console pixels -- two source
    /// bytes -- land on exactly one screen byte, with no shifting across a
    /// boundary. Doing it a pixel at a time instead costs a load, a
    /// read-modify-write and a store for each of the 25,600 pixels, which on
    /// this processor is most of a frame's budget.
    mutating func present(_ console: Console, on playdate: Playdate) {
        guard let frame = playdate.graphics.getFrame() else { return }
        let rowSize = Int(LCD_ROWSIZE)
        updateShades(for: console.palette())

        sinceFullFrame += 1
        if sinceFullFrame >= Self.fullFrameInterval {
            sinceFullFrame = 0
            for index in previous.indices { previous[index] = 0xFF }
        }

        var counts = ColourCounts()
        var firstChanged = Screen.height
        var lastChanged = -1
        let rowBytes = Screen.width >> 2
        shades.withUnsafeBufferPointer { levels in
            Dither.thresholds.withUnsafeBufferPointer { thresholds in
              previous.withUnsafeMutableBufferPointer { seen in
                console.withMemory { raw in
                    for y in 0..<Screen.height {
                        var destination = (Self.originY + y) * rowSize + (Self.originX >> 3)
                        var source = Address.framebuffer + ((Screen.width * y) >> 2)
                        let thresholdRow = (y & 7) << 3

                        // Unchanged rows keep their pixels on the panel, but
                        // still have to be counted, so the tally comes from the
                        // copy rather than from a conversion.
                        var changed = false
                        for offset in 0..<rowBytes where raw[source + offset] != seen[(y * rowBytes) + offset] {
                            changed = true
                            break
                        }
                        if !changed {
                            for offset in 0..<rowBytes {
                                let byte = seen[(y * rowBytes) + offset]
                                counts.increment(Int(byte & 0x3))
                                counts.increment(Int((byte >> 2) & 0x3))
                                counts.increment(Int((byte >> 4) & 0x3))
                                counts.increment(Int((byte >> 6) & 0x3))
                            }
                            continue
                        }
                        for offset in 0..<rowBytes {
                            seen[(y * rowBytes) + offset] = raw[source + offset]
                        }
                        if y < firstChanged { firstChanged = y }
                        if y > lastChanged { lastChanged = y }

                        // 20 bytes out, 40 bytes in, per row.
                        for byteIndex in 0..<(Screen.width >> 3) {
                            let low = raw[source]
                            let high = raw[source + 1]
                            source += 2

                            let x = byteIndex << 3
                            var bits: UInt8 = 0
                            // The leftmost pixel is the lowest two bits of the
                            // first source byte and the highest bit of the
                            // destination byte, so the two walk opposite ways.
                            for pixel in 0..<4 {
                                let colour = Int((low >> UInt8(pixel << 1)) & 0x3)
                                counts.increment(colour)
                                if levels[colour] > thresholds[thresholdRow + ((x + pixel) & 7)] {
                                    bits |= UInt8(0x80) >> UInt8(pixel)
                                }
                            }
                            for pixel in 0..<4 {
                                let colour = Int((high >> UInt8(pixel << 1)) & 0x3)
                                counts.increment(colour)
                                if levels[colour] > thresholds[thresholdRow + ((x + 4 + pixel) & 7)] {
                                    bits |= UInt8(0x08) >> UInt8(pixel)
                                }
                            }

                            frame[destination] = bits  // 1 = white
                            destination += 1
                        }
                    }
                }
              }
            }
        }
        colourCounts = [counts.zero, counts.one, counts.two, counts.three]

        guard lastChanged >= firstChanged else { return }
        playdate.graphics.markUpdatedRows(
            Int32(Self.originY + firstChanged), Int32(Self.originY + lastChanged))
    }
}

/// Four counters in registers rather than an array: the array form costs a
/// uniqueness check and a bounds check on every one of 25,600 pixels.
private struct ColourCounts {
    var zero = 0
    var one = 0
    var two = 0
    var three = 0

    @inline(__always)
    mutating func increment(_ index: Int) {
        switch index {
        case 0: zero += 1
        case 1: one += 1
        case 2: two += 1
        default: three += 1
        }
    }
}
