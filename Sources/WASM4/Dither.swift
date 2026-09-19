/// Reduces the console's four colours to black and white.
///
/// Lives beside the console rather than the display code because the cover
/// generator needs the same conversion, and the covers should match the game.
public enum Dither {
    /// Bayer 8x8, scaled to the 0-255 range brightness uses.
    ///
    /// Eight because that is what the SDK's own example uses, and because an
    /// `LCDPattern` is an 8x8 tile. Indexed by source pixel, which equals the
    /// screen pixel only because the picture's origin (120, 40) is a multiple
    /// of 8; move it off that and the pattern will crawl.
    public static let thresholds: [UInt8] = {
        let base: [UInt8] = [
            0, 32, 8, 40, 2, 34, 10, 42,
            48, 16, 56, 24, 50, 18, 58, 26,
            12, 44, 4, 36, 14, 46, 6, 38,
            60, 28, 52, 20, 62, 30, 54, 22,
            3, 35, 11, 43, 1, 33, 9, 41,
            51, 19, 59, 27, 49, 17, 57, 25,
            15, 47, 7, 39, 13, 45, 5, 37,
            63, 31, 55, 23, 61, 29, 53, 21,
        ]
        // Centre each level in its bucket: (n + 0.5) / 64 of full scale.
        return base.map { UInt8((Int($0) * 255 + 128) / 64) }
    }()

    /// How brightness is assigned to the four palette entries. Both read the
    /// cart's live palette, so both follow a cart that recolours itself.
    public enum Policy {
        /// Absolute brightness. Faithful, but at 1:1 a near-white background
        /// still gets one black pixel in sixteen, which reads as noise.
        case absolute
        /// Brightness stretched across the colours on screen, so the darkest
        /// is solid black and the lightest solid white. A whole-palette fade
        /// no longer shows, because the stretch removes it.
        case stretched
        /// No dithering: every colour becomes solid black or white. At 1:1 a
        /// dither destroys single-pixel detail, and pixel art is mostly that.
        /// Two colours on the same side become indistinguishable.
        case threshold
    }

    /// Rec. 601 luma, integer only.
    @inline(__always)
    public static func luma(_ colour: UInt32) -> UInt8 {
        let r = UInt32((colour >> 16) & 0xFF)
        let g = UInt32((colour >> 8) & 0xFF)
        let b = UInt32(colour & 0xFF)
        return UInt8((r &* 77 &+ g &* 151 &+ b &* 28) >> 8)
    }

    /// The dither level for each of the four palette entries.
    ///
    /// Compare a level against `thresholds[(y & 7) * 8 + (x & 7)]`: greater
    /// means white.
    ///
    /// `coverage` is the pixel count per colour in the frame being converted.
    /// It decides which colours count as present, and where `.threshold` puts
    /// the split. Pass nil when it is not known.
    public static func levels(
        palette: (UInt32, UInt32, UInt32, UInt32), policy: Policy, coverage: [Int]? = nil
    ) -> [UInt8] {
        // Coverage, not mere presence: six stray pixels in one cart were
        // enough to push its text into a dither. Half a per cent is the cutoff.
        let present: [Bool]
        if let coverage {
            let minimum = (Screen.width * Screen.height) / 200
            present = coverage.map { $0 >= minimum }
        } else {
            present = [true, true, true, true]
        }
        return levels(palette: palette, policy: policy, present: present, coverage: coverage)
    }

    private static func levels(
        palette: (UInt32, UInt32, UInt32, UInt32), policy: Policy,
        present: [Bool], coverage: [Int]?
    ) -> [UInt8] {
        let absolute = [luma(palette.0), luma(palette.1), luma(palette.2), luma(palette.3)]
        switch policy {
        case .absolute:
            return absolute
        case .threshold:
            let stretched = levels(
                palette: palette, policy: .stretched, present: present, coverage: coverage)

            // Split between the two colours covering the most screen, which
            // are almost always foreground and background. A fixed midpoint
            // gets it wrong when one sits near the middle: one cart's message
            // panel landed on 135 against a split of 128 and vanished.
            var split = 128
            if let coverage {
                var first = -1
                var second = -1
                for index in 0..<4 where present[index] {
                    if first < 0 || coverage[index] > coverage[first] {
                        second = first
                        first = index
                    } else if second < 0 || coverage[index] > coverage[second] {
                        second = index
                    }
                }
                if first >= 0 && second >= 0 {
                    let low = min(stretched[first], stretched[second])
                    let high = max(stretched[first], stretched[second])
                    if high > low { split = (Int(low) + Int(high) + 1) / 2 }
                }
            }
            return stretched.map { $0 >= UInt8(split) ? 255 : 0 }

        case .stretched:
            var lowest = UInt8(255)
            var highest = UInt8(0)
            for index in 0..<4 where present[index] {
                lowest = min(lowest, absolute[index])
                highest = max(highest, absolute[index])
            }
            guard highest > lowest else {
                // One colour, or several of identical brightness: nothing to
                // stretch, so fall back to absolute brightness.
                return absolute
            }

            // Rescale so the darkest lands on 0 and the lightest on 255, both
            // outside every threshold and so solid. The rest keep their
            // relative brightness: ranking evenly would put a dark shadow at
            // mid-grey and make it shimmer against a dark background.
            let span = Int(highest) - Int(lowest)
            var levels: [UInt8] = [0, 0, 0, 0]
            for index in 0..<4 {
                let clamped = min(max(absolute[index], lowest), highest)
                levels[index] = UInt8((Int(clamped) - Int(lowest)) * 255 / span)
            }
            return levels
        }
    }
}
