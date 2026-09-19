import CPlaydate
import WASM4
import WasmKit

/// The application: a shelf of carts, and a console running one of them.
///
/// Held alive by the entry point and reached from the system's callbacks
/// through their `userdata` pointer, which is what keeps this state out of
/// global scope.
final class App {
    private enum Mode {
        case shelf
        case playing
    }

    private let playdate: Playdate
    private let engine: Engine

    private var mode: Mode = .shelf
    private var shelf = Shelf()
    private var console: Console?
    private var display = Display()
    private var input = Input()
    private var saves = SaveFile()
    private let audio = Audio()

    private var ditherMenuItem: OpaquePointer?
    private var showStats = false
    private var lastFrameMillis: UInt32 = 0
    private var needsShelfRedraw = true

    private var cycleCounterWorks = false
    private var presentCycles: UInt64 = 0

    /// Cart time owed, in microseconds, and the clock reading it was last
    /// measured from.
    private var owedMicros = 0
    private var lastTick: UInt32 = 0

    /// One console frame's worth of cart time. WASM-4 defines `update` as
    /// running at 60 Hz, which no Playdate refresh rate divides evenly, so the
    /// two clocks are kept separate and reconciled here.
    private static let frameMicros = 1_000_000 / 60

    /// The most cart time that can be owed at once. Past this the debt is
    /// dropped: a cart the hardware cannot keep up with then runs slow, which
    /// is visible but playable, where letting the debt run would mean a
    /// callback that never ends.
    private static let maxOwedMicros = 100_000

    /// The display period, at the 50 Hz refresh rate set below.
    private static let displayPeriodMillis: UInt32 = 20

    /// What one console frame has been costing, smoothed. A second frame is
    /// only started when it is expected to finish inside the display period:
    /// running one that overruns does not make the cart faster, it just means
    /// the screen is refreshed half as often, and two slow frames back to back
    /// are also what brings a cart within reach of the ten-second run loop
    /// watchdog that resets the device.
    private var consoleFrameCost: UInt32 = 0

    init(playdate: Playdate) {
        self.playdate = playdate

        // The stack is one flat allocation and a failure faults rather than
        // throwing, so it is sized rather than left at the 512 KB default. The
        // threading model is explicit because the default resolves to direct
        // threading on ARM, which Embedded Swift compiles out.
        engine = Engine(
            configuration: EngineConfiguration(threadingModel: .direct, stackSize: 64 * 1024))
    }

    // MARK: - Lifecycle

    func start(userdata: UnsafeMutableRawPointer) {
        var error: UnsafePointer<CChar>?
        if let font = playdate.graphics.loadFont(
            "/System/Fonts/Asheville-Sans-14-Bold.pft", &error)
        {
            playdate.graphics.setFont(font)
        } else {
            playdate.log("w4: failed to load system font")
        }


        audio.start(on: playdate)
        addMenuItems(userdata: userdata)

        // A queue of eight: the manual suggests five is adequate at 30 fps, and
        // the extra costs nothing.
        playdate.system.setButtonCallback(
            { button, down, _, userdata in
                App.from(userdata).input.record(button, down: down != 0)
                return 0
            }, userdata, 8)

        // 50 is the panel's ceiling. A cart that can keep up is then shown at
        // 50 rather than 30; one that cannot is shown as often as it manages.
        playdate.display.setRefreshRate(50)
        playdate.system.setUpdateCallback({ userdata in App.from(userdata).update() }, userdata)
    }

    /// Recovers the instance a callback was registered with.
    @inline(__always)
    static func from(_ userdata: UnsafeMutableRawPointer?) -> App {
        Unmanaged<App>.fromOpaque(userdata!).takeUnretainedValue()
    }

    /// Reached through the Menu button, which keeps all six game buttons
    /// available to carts. Three is the documented maximum the system menu
    /// accepts, and these are the three; a fourth would be silently ignored.
    private func addMenuItems(userdata: UnsafeMutableRawPointer) {
        let system = playdate.system

        _ = system.addMenuItem("cart list", { App.from($0).returnToShelf() }, userdata)

        // Dithering is off by default: at 1:1 it destroys single-pixel features,
        // and pixel art is mostly single-pixel features. Turning it on trades
        // crispness for keeping colours that would otherwise merge.
        ditherMenuItem = system.addCheckmarkMenuItem(
            "dither",
            display.ditherPolicy == .stretched ? 1 : 0,
            { userdata in
                let app = App.from(userdata)
                guard let item = app.ditherMenuItem else { return }
                let dithered = app.playdate.system.getMenuItemValue(item) != 0
                app.display.ditherPolicy = dithered ? .stretched : .threshold
            }, userdata)

        _ = system.addCheckmarkMenuItem(
            "show stats", 0, { App.from($0).showStats.toggle() }, userdata)
    }

    // MARK: - Carts

    private func play(cart index: Int) {
        let entry = carts[index]
        guard let bytes = playdate.readBundledFile(at: entry.path, limit: Screen.memorySize)
        else { return }

        saves.use(cart: entry.path)
        do {
            let loaded = try Console(cart: bytes, engine: engine)
            loaded.peripherals.tone = { [audio] frequency, duration, volume, flags in
                audio.post(
                    frequency: frequency, duration: duration, volume: volume, flags: flags)
            }
            // The reference back to this object is a cycle, broken by
            // `returnToShelf` dropping the console.
            loaded.peripherals.diskRead = { [self] buffer in
                saves.read(into: buffer, on: playdate)
            }
            loaded.peripherals.diskWrite = { [self] buffer in
                saves.write(from: buffer, on: playdate)
            }
            console = loaded
            mode = .playing
            owedMicros = 0
            consoleFrameCost = 0
            lastTick = playdate.system.getCurrentTimeMilliseconds()
            display.invalidate()
            playdate.graphics.clear(0)
        } catch {
            playdate.log("w4: cart failed to instantiate")
        }
    }

    private func returnToShelf() {
        console = nil
        mode = .shelf
        needsShelfRedraw = true
    }

    // MARK: - Frame

    private func update() -> Int32 {
        switch mode {
        case .shelf: return updateShelf()
        case .playing: return updatePlaying()
        }
    }

    private func updateShelf() -> Int32 {
        var changed = shelf.advance(crankChange: playdate.system.getCrankChange())

        var pushed = PDButtons(rawValue: 0)
        playdate.system.getButtonState(nil, &pushed, nil)
        if pushed.bits & kButtonDown.bits != 0 { changed = shelf.move(by: 1) || changed }
        if pushed.bits & kButtonUp.bits != 0 { changed = shelf.move(by: -1) || changed }

        if pushed.bits & kButtonA.bits != 0 {
            play(cart: shelf.selection)
            return 1
        }

        if changed || needsShelfRedraw {
            needsShelfRedraw = false
            drawShelf()
        }
        return 1
    }

    private func updatePlaying() -> Int32 {
        guard let console else { return 1 }

        let system = playdate.system
        let started = system.getCurrentTimeMilliseconds()

        // Run against the cart's own clock rather than a fixed count per
        // callback, so a cart keeps its proper speed on a display that cannot
        // match it. `&-` because the millisecond clock wraps, and the gap is
        // capped before the conversion because `Int` is 32 bits here: a device
        // that slept between two callbacks would otherwise overflow it.
        let gapMillis = min(started &- lastTick, 1000)
        owedMicros += Int(gapMillis) * 1000
        lastTick = started
        if owedMicros > Self.maxOwedMicros {
            owedMicros = Self.maxOwedMicros
        }

        do {
            var lastMark = started
            while owedMicros >= Self.frameMicros {
                try console.frame(gamepad: input.gamepad(on: playdate))
                audio.tick()
                owedMicros -= Self.frameMicros

                let now = system.getCurrentTimeMilliseconds()
                let cost = now &- lastMark
                lastMark = now
                // Rises at once and falls gently, so one cheap frame does not
                // invite an expensive one.
                consoleFrameCost =
                    cost > consoleFrameCost ? cost : (consoleFrameCost &* 3 &+ cost) / 4
                if (now &- started) &+ consoleFrameCost > Self.displayPeriodMillis {
                    break
                }
            }
        } catch {
            playdate.log("w4: cart trapped, returning to shelf")
            returnToShelf()
            return 1
        }
        lastFrameMillis = system.getCurrentTimeMilliseconds() &- started

        // Every callback presents, so the picture is as fresh as the hardware
        // allows: pairing frames instead halves the rate a viewer sees without
        // buying the cart any time.
        display.present(console, on: playdate)


        if showStats {
            system.drawFPS(4, 4)
            playdate.draw("ms:", value: lastFrameMillis, x: 4, y: 216)
        }
        return 1
    }

    private func drawShelf() {
        let graphics = playdate.graphics
        graphics.clear(1)  // 1 = white

        playdate.draw("WASM-4 on WasmKit", x: 12, y: 8)
        playdate.draw("Crank or D-pad. A to play.", x: 12, y: 214)

        // The list occupies the left of the screen and the cover the right: a
        // 160x160 image and a readable list fit side by side on a 400-pixel
        // display, and little else does.
        let visibleRows = 7
        let firstRow = max(0, min(max(0, carts.count - visibleRows), shelf.selection - 3))
        var y: Int32 = 38
        for index in firstRow..<min(carts.count, firstRow + visibleRows) {
            if index == shelf.selection {
                graphics.fillRect(8, y - 3, 180, 20, 0)  // 0 = black
                _ = graphics.setDrawMode(kDrawModeInverted)
                playdate.draw(carts[index].title, x: 14, y: y)
                _ = graphics.setDrawMode(kDrawModeCopy)
            } else {
                playdate.draw(carts[index].title, x: 14, y: y)
            }
            y += 22
        }

        // Loaded and freed per redraw, which happens only when the selection
        // changes. Holding eleven bitmaps open would cost more than it saves.
        carts[shelf.selection].cover.withUTF8Buffer { bytes in
            var error: UnsafePointer<CChar>?
            let path = UnsafeRawPointer(bytes.baseAddress!).assumingMemoryBound(to: CChar.self)
            if let bitmap = graphics.loadBitmap(path, &error) {
                graphics.drawBitmap(bitmap, 224, 40, kBitmapUnflipped)
                graphics.freeBitmap(bitmap)
            }
        }

        graphics.markUpdatedRows(0, Int32(LCD_ROWS) - 1)
    }
}


