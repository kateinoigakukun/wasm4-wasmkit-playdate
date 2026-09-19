import CPlaydate
import WASM4

/// Sound output.
///
/// The Playdate's audio callback runs on its own task at higher priority than
/// the game, asking for about 256 samples (5.8 ms) at a time. Synthesis happens
/// inside that callback, so a slow game frame cannot make the sound stutter.
///
/// The SDK offers no way to lock against the audio task, so everything the game
/// task has to say crosses through the single-producer ring below.
final class Audio {
    struct ToneCommand {
        var frequency: UInt32 = 0
        var duration: UInt32 = 0
        var volume: UInt32 = 0
        var flags: UInt32 = 0
    }

    /// A power of two so the wrap is a mask. Sixteen pending tones is far more
    /// than four channels can consume in one callback.
    private static let capacity = 16
    private static let mask = UInt32(capacity - 1)

    /// Everything both tasks touch. It lives in an explicit allocation because
    /// the atomic helpers take an address, and only a stable address means
    /// anything across two tasks: `&object.property` is not guaranteed to be
    /// the property's own storage.
    private struct Shared {
        /// Written by the game task, read by the audio task.
        var writeIndex: UInt32 = 0
        /// Written by the audio task, read by the game task.
        var readIndex: UInt32 = 0
        /// The console frame counter, advanced by the game task.
        ///
        /// The sound chip is owned entirely by the audio task. This counter is
        /// the one piece of its state the game task needs to move, so it is
        /// published across atomically rather than written into the chip
        /// directly -- doing the latter would race with the callback that is
        /// rendering from it.
        var frameTicks: UInt32 = 0
    }

    private let shared: UnsafeMutablePointer<Shared>
    private let ring: UnsafeMutablePointer<ToneCommand>

    /// Owned by the audio task. The game task never touches it.
    private var apu = APU()

    init() {
        shared = .allocate(capacity: 1)
        shared.initialize(to: Shared())
        ring = .allocate(capacity: Self.capacity)
        ring.initialize(repeating: ToneCommand(), count: Self.capacity)
    }

    /// Registers the callback with the system, which then owns this object.
    /// Stereo, so headphone output is not one-sided; the two channels carry the
    /// same signal.
    func start(on playdate: Playdate) {
        _ = playdate.api.pointee.sound.pointee.addSource(
            { context, left, right, count in
                Unmanaged<Audio>.fromOpaque(context!).takeUnretainedValue()
                    .render(left: left, right: right, count: count)
            },
            Unmanaged.passRetained(self).toOpaque(),
            1)
    }

    // MARK: - Game task

    /// Posts a tone. Never blocks; drops the tone if the ring is full, which
    /// cannot happen in practice and is preferable to stalling a frame.
    func post(frequency: UInt32, duration: UInt32, volume: UInt32, flags: UInt32) {
        let write = w4_atomic_load(&shared.pointee.writeIndex)
        let read = w4_atomic_load(&shared.pointee.readIndex)
        guard write &- read < UInt32(Self.capacity) else { return }

        ring[Int(write & Self.mask)] = ToneCommand(
            frequency: frequency, duration: duration, volume: volume, flags: flags)
        // Release: the command must be visible before the index that publishes it.
        w4_atomic_store(&shared.pointee.writeIndex, write &+ 1)
    }

    /// Advances the console frame counter. Called once per console frame.
    func tick() {
        // Single producer, so a plain read-modify-write is safe here; the store
        // is what publishes it.
        w4_atomic_store(
            &shared.pointee.frameTicks, w4_atomic_load(&shared.pointee.frameTicks) &+ 1)
    }

    // MARK: - Audio task

    private func render(
        left: UnsafeMutablePointer<Int16>?, right: UnsafeMutablePointer<Int16>?, count: Int32
    ) -> Int32 {
        guard let left, count > 0 else { return 0 }

        // Drain whatever the game task posted since the last callback.
        let write = w4_atomic_load(&shared.pointee.writeIndex)
        var read = w4_atomic_load(&shared.pointee.readIndex)
        while read != write {
            let command = ring[Int(read & Self.mask)]
            apu.tone(
                frequency: command.frequency, duration: command.duration,
                volume: command.volume, flags: command.flags)
            read &+= 1
        }
        w4_atomic_store(&shared.pointee.readIndex, read)

        apu.advance(to: Int(w4_atomic_load(&shared.pointee.frameTicks)))

        let samples = Int(count)
        // Telling the engine the source is silent lets it skip mixing this
        // buffer entirely, which is the common case: a cart is usually playing
        // nothing. The clock still advances so the chip's timing stays
        // monotonic.
        if apu.isSilent {
            apu.skip(samples)
            return 0
        }

        apu.render(into: UnsafeMutableBufferPointer(start: left, count: samples), count: samples)

        // The speaker is mono, but headphones are not, so a stereo source still
        // has to fill both sides.
        if let right {
            for index in 0..<samples {
                right[index] = left[index]
            }
        }
        return 1
    }
}
