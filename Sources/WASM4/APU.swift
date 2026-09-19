/// The WASM-4 sound chip: two pulse channels, a triangle, and noise.
///
/// Translated from the reference `apu.c` and verified against it sample for
/// sample, with two deliberate departures: the pulse channels are plain squares
/// rather than band-limited, and the mix is mono because the speaker is.
/// Envelope, tick and noise maths are exact -- those decide whether a tune
/// sounds right; band-limiting only refines timbre.
///
/// `Float` throughout, never `Double`: this Cortex-M7 has a single-precision
/// FPU, so `Double` would be emulated in software inside the audio callback.
public struct APU {
    public static let sampleRate: Int = 44100

    /// Roughly 15% of full scale, as the reference uses, leaving headroom for
    /// four channels summed without a limiter.
    static let maxVolume: Float = Float(0x1333)
    /// The triangle is quieter in nature, so the reference gives it more.
    static let maxVolumeTriangle: Float = Float(0x2000)
    /// A forced one-millisecond release, applied to the triangle when a tone
    /// asks for none, to stop it popping.
    static let triangleReleaseSamples: Int = sampleRate / 1000

    struct Channel {
        var startTime: Int = 0
        var attackTime: Int = 0
        var decayTime: Int = 0
        var sustainTime: Int = 0
        var releaseTime: Int = 0
        var endTick: Int = 0

        var sustainVolume: Float = 0
        var peakVolume: Float = 0

        var startFrequency: Float = 0
        var endFrequency: Float = 0

        var phase: Float = 0
        var dutyCycle: Float = 0.5
        var pan: Int = 0

        /// Noise only.
        var seed: UInt16 = 0x0001
        var lastRandom: Float = 0
    }

    var channels = [Channel](repeating: Channel(), count: 4)
    /// Samples elapsed since power-on.
    var time: Int = 0
    /// Frames elapsed since power-on; the cart's notion of duration.
    var ticks: Int = 0

    public init() {
        channels[3].seed = 0x0001
    }

    /// The frame counter, for callers that advance it.
    public var frameCount: Int { ticks }

    /// Sets the frame counter. The game task advances it but the audio task
    /// owns everything else here, so it is handed in rather than mutated.
    public mutating func advance(to ticks: Int) {
        self.ticks = ticks
    }

    /// Applies a `tone` call.
    public mutating func tone(frequency: UInt32, duration: UInt32, volume: UInt32, flags: UInt32) {
        let channelIndex = Int(flags & 0x3)
        let mode = Int((flags >> 2) & 0x3)
        let pan = Int((flags >> 4) & 0x3)
        let noteMode = (flags & 0x40) != 0

        var startFrequency = Float(frequency & 0xFFFF)
        var endFrequency = Float((frequency >> 16) & 0xFFFF)
        if noteMode {
            startFrequency = Self.noteFrequency(UInt32(frequency & 0xFFFF))
            let end = (frequency >> 16) & 0xFFFF
            endFrequency = end == 0 ? 0 : Self.noteFrequency(end)
        }

        let sustain = Int(duration & 0xFF)
        let release = Int((duration >> 8) & 0xFF)
        let decay = Int((duration >> 16) & 0xFF)
        let attack = Int((duration >> 24) & 0xFF)

        let sustainVolume = Float(min(UInt32(100), volume & 0xFF)) / 100
        let peakRaw = min(UInt32(100), (volume >> 8) & 0xFF)

        let isTriangle = channelIndex == 2
        let ceiling = isTriangle ? Self.maxVolumeTriangle : Self.maxVolume

        var channel = channels[channelIndex]

        // The phase is only restarted when the channel was not already
        // sounding; retriggering mid-note would click.
        if time > channel.releaseTime && ticks != channel.endTick {
            channel.phase = isTriangle ? 0.25 : 0
        }

        @inline(__always)
        func samples(_ frames: Int) -> Int { Self.sampleRate * frames / 60 }

        channel.startTime = time
        channel.attackTime = channel.startTime + samples(attack)
        channel.decayTime = channel.attackTime + samples(decay)
        channel.sustainTime = channel.decayTime + samples(sustain)
        channel.releaseTime = channel.sustainTime + samples(release)
        if isTriangle && release == 0 {
            channel.releaseTime += Self.triangleReleaseSamples
        }
        channel.endTick = ticks + attack + decay + sustain + release

        channel.sustainVolume = ceiling * sustainVolume
        channel.peakVolume = peakRaw != 0 ? ceiling * Float(peakRaw) / 100 : ceiling
        channel.startFrequency = startFrequency
        channel.endFrequency = endFrequency
        channel.pan = pan
        // Mode 3 is documented as a 3/4 duty cycle but both reference
        // implementations fold it into 1/4. The code is authoritative.
        channel.dutyCycle = [0.125, 0.25, 0.5, 0.25][mode]

        channels[channelIndex] = channel
    }

    /// MIDI note plus a 1/256-semitone bend, relative to A440.
    static func noteFrequency(_ packed: UInt32) -> Float {
        let note = Float(packed & 0xFF)
        let bend = Float((packed >> 8) & 0xFF) / 256
        return exp2(x: (note - 69 + bend) / 12) * 440
    }

    /// Two raised to a power, without libm: this module has no C dependency,
    /// and Embedded Swift brings no math library. A minimax polynomial on the
    /// fraction, which is far more accuracy than a note frequency needs.
    static func exp2(x: Float) -> Float {
        let whole = x < 0 ? Int(x) - 1 : Int(x)
        let fraction = x - Float(whole)

        // 2^f for f in [0, 1), maximum error around 1e-5.
        let f = fraction
        var result: Float = 1
        result += f * 0.693_147_18
        result += f * f * 0.240_226_51
        result += f * f * f * 0.055_504_11
        result += f * f * f * f * 0.009_618_13
        result += f * f * f * f * f * 0.001_339_89

        var scale: Float = 1
        var remaining = whole
        while remaining > 0 {
            scale *= 2
            remaining -= 1
        }
        while remaining < 0 {
            scale /= 2
            remaining += 1
        }
        return result * scale
    }

    @inline(__always)
    static func ramp(_ from: Float, _ to: Float, _ time: Int, _ start: Int, _ end: Int) -> Float {
        if time >= end { return to }
        let progress = Float(time - start) / Float(end - start)
        return from + (to - from) * progress
    }

    /// True when no channel would produce anything this cycle, so the caller
    /// can tell the engine to skip mixing. Carts are usually silent.
    public var isSilent: Bool {
        for channel in channels where time < channel.releaseTime || ticks == channel.endTick {
            return false
        }
        return true
    }

    /// Advances the sample clock without producing anything, so that the chip's
    /// notion of time stays monotonic across cycles that were skipped.
    public mutating func skip(_ count: Int) {
        time += count
    }

    /// Renders `count` mono samples, summing all four channels.
    public mutating func render(into output: UnsafeMutableBufferPointer<Int16>, count: Int) {
        for index in 0..<count {
            var sum: Float = 0

            for channelIndex in 0..<4 {
                var channel = channels[channelIndex]
                // A zero-length tone still sounds for exactly one frame, which
                // is what the endTick comparison preserves.
                guard time < channel.releaseTime || ticks == channel.endTick else { continue }

                let frequency: Float
                if channel.endFrequency > 0 {
                    frequency = Self.ramp(
                        channel.startFrequency, channel.endFrequency,
                        time, channel.startTime, channel.releaseTime)
                } else {
                    frequency = channel.startFrequency
                }

                // Follows the reference exactly. The guard on the release
                // branch is what keeps a zero-release tone audible for the one
                // frame it is meant to sound.
                let volume: Float
                if time >= channel.sustainTime
                    && (channel.releaseTime - channel.sustainTime) > Self.triangleReleaseSamples
                {
                    volume = Self.ramp(
                        channel.sustainVolume, 0, time, channel.sustainTime, channel.releaseTime)
                } else if time >= channel.decayTime {
                    volume = channel.sustainVolume
                } else if time >= channel.attackTime {
                    volume = Self.ramp(
                        channel.peakVolume, channel.sustainVolume, time, channel.attackTime,
                        channel.decayTime)
                } else {
                    volume = Self.ramp(
                        0, channel.peakVolume, time, channel.startTime, channel.attackTime)
                }

                var sample: Float = 0
                switch channelIndex {
                case 3:
                    // 16-bit linear feedback shift register, advanced at a rate
                    // proportional to the square of the frequency.
                    channel.phase += frequency * frequency
                        / (1_000_000 / Float(Self.sampleRate) * Float(Self.sampleRate))
                    while channel.phase > 0 {
                        channel.phase -= 1
                        var seed = channel.seed
                        seed ^= seed >> 7
                        seed ^= seed << 9
                        seed ^= seed >> 13
                        channel.seed = seed
                        channel.lastRandom = Float(2 * Int(seed & 1) - 1)
                    }
                    sample = volume * channel.lastRandom
                case 2:
                    channel.phase += frequency / Float(Self.sampleRate)
                    if channel.phase >= 1 { channel.phase -= 1 }
                    sample = volume * (2 * abs(2 * channel.phase - 1) - 1)
                default:
                    channel.phase += frequency / Float(Self.sampleRate)
                    if channel.phase >= 1 { channel.phase -= 1 }
                    // Plain square rather than a band-limited pulse; see the
                    // note at the top of this file.
                    sample = channel.phase < channel.dutyCycle ? volume : -volume
                }

                sum += sample
                channels[channelIndex] = channel
            }

            // Mono: the Playdate has one speaker, so the pan bits are ignored.
            let clamped = max(-32768, min(32767, sum))
            output[index] = Int16(clamped)
            time += 1
        }
    }
}
