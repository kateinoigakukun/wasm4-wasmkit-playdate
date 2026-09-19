import CPlaydate

/// Button reading.
///
/// The manual warns that polling misses fast presses at this frame rate. It
/// matters doubly here: the display runs at 30 Hz while carts expect 60, so two
/// console frames share one display frame and a single poll would hand both the
/// same sample. Events are recorded as they arrive and split across the two.
struct Input {
    /// Events since the last update, newest last.
    private var events: [(mask: UInt32, down: Bool)] = []

    /// The buttons the console considers held, maintained by replaying events
    /// and resynchronised from the real state once per display frame so it
    /// cannot drift if the queue ever overflows.
    private var held: UInt32 = 0

    mutating func record(_ button: PDButtons, down: Bool) {
        events.append((button.bits, down))
    }

    /// Maps the Playdate's buttons onto the byte the console exposes at
    /// GAMEPAD1. In the vendor's header B is bit 4 and A is bit 5, the reverse
    /// of alphabetical order, which is an easy way to ship swapped controls.
    @inline(__always)
    private func gamepadByte(_ buttons: UInt32) -> UInt8 {
        var gamepad: UInt8 = 0
        if buttons & kButtonA.bits != 0 { gamepad |= 0x01 }  // BUTTON_1 / X
        if buttons & kButtonB.bits != 0 { gamepad |= 0x02 }  // BUTTON_2 / Z
        if buttons & kButtonLeft.bits != 0 { gamepad |= 0x10 }
        if buttons & kButtonRight.bits != 0 { gamepad |= 0x20 }
        if buttons & kButtonUp.bits != 0 { gamepad |= 0x40 }
        if buttons & kButtonDown.bits != 0 { gamepad |= 0x80 }
        return gamepad
    }

    /// The gamepad byte for the next console frame, consuming whatever has
    /// arrived since the last one.
    ///
    /// A button that goes down and up between two console frames is still
    /// reported as held for the frame that consumes it: carts detect presses by
    /// diffing against the previous frame, so a press that never appears held
    /// is a press that never happened.
    mutating func gamepad(on playdate: Playdate) -> UInt8 {
        var transient: UInt32 = 0
        for event in events {
            if event.down {
                held |= event.mask
                transient |= event.mask
            } else {
                held &= ~event.mask
            }
        }
        events.removeAll(keepingCapacity: true)
        let byte = gamepadByte(held | transient)

        // Resynchronise from the real state, so a dropped or missed event
        // cannot leave a button stuck down for the rest of the session.
        var current = PDButtons(rawValue: 0)
        playdate.system.getButtonState(&current, nil, nil)
        held = current.bits

        return byte
    }
}
