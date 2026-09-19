import WasmKit

public enum ConsoleError: Error {
    case cartHasNoUpdateFunction
}

/// A WASM-4 console: one cart, its memory, and the host functions it calls.
///
/// Deliberately free of any Playdate dependency so the same code runs in a
/// command-line harness, which is what `tools/cartrun` does.
public final class Console {
    /// Sound and save data are handled by the host; install them here.
    public let peripherals = Peripherals()

    private let memory: Memory
    private let startFunction: Function?
    private let updateFunction: Function
    private var isFirstFrame = true

    /// The stack the cart runs on, made once and used for every frame.
    ///
    /// `invoke` would otherwise allocate one per call, which on a small device
    /// costs more than some carts' `update` does.
    private var stack: ExecutionStack

    public init(cart: [UInt8], engine: Engine) throws {
        let store = Store(engine: engine)

        // The host owns the memory and the cart imports it. Every published
        // cart is linked with --import-memory, and the reference runtimes force
        // this even for the one cart that also exports its own.
        let memory = try Memory(store: store, type: MemoryType(min: 1, max: 1))
        self.memory = memory

        var imports = Imports()
        imports.define(module: "env", name: "memory", memory)
        Console.defineHostFunctions(
            into: &imports, store: store, memory: memory, peripherals: peripherals)

        // The power-on state must be written *before* the cart is instantiated.
        // A cart's data segments are applied during instantiation and land in
        // this same address space -- carts routinely place sprites and strings
        // just above the framebuffer -- so writing defaults afterwards would
        // erase them.
        Console.writePowerOnState(memory)

        let module = try parseWasm(bytes: cart)
        let instance = try module.instantiate(store: store, imports: imports)

        // Local until the stored properties are all in place, then moved into
        // the console.
        var stack = ExecutionStack(engine: engine)

        // Carts produced by toolchains targeting a "reactor" model export an
        // initialiser; the reference runtimes call both spellings if present,
        // before the cart's own start().
        for name in ["_start", "_initialize"] {
            if let initializer = instance.exports[function: name] {
                _ = try initializer.invoke(on: &stack)
            }
        }

        guard let update = instance.exports[function: "update"] else {
            throw ConsoleError.cartHasNoUpdateFunction
        }
        self.updateFunction = update
        self.startFunction = instance.exports[function: "start"]
        self.stack = stack
    }

    /// Writes the documented power-on state.
    ///
    /// A freshly created memory is already zero, so only the non-zero defaults
    /// are set here. To restart a cart, build a new `Console`: rewinding this
    /// state in place would leave the cart's own globals and heap untouched.
    private static func writePowerOnState(_ memory: Memory) {
        memory.withUnsafeMutableBufferPointer(offset: 0, count: Screen.memorySize) { raw in
            // Four greens. Carts routinely overwrite this at run time.
            let defaults: [UInt32] = [0xe0f8cf, 0x86c06c, 0x306850, 0x071821]
            for (index, colour) in defaults.enumerated() {
                Bytes.writeUInt32(raw, at: Address.palette + index * 4, colour)
            }
            raw[Address.drawColors] = 0x03
            raw[Address.drawColors + 1] = 0x12
            // Off-screen, so a cart reading the mouse sees no pointer.
            Bytes.writeUInt16(raw, at: Address.mouseX, 0x7fff)
            Bytes.writeUInt16(raw, at: Address.mouseY, 0x7fff)
        }
    }

    /// Advances the console by one frame.
    ///
    /// The order here is load-bearing and matches the reference runtime: input
    /// is visible to the cart before `update` runs, the framebuffer is cleared
    /// before `update` rather than after, and the very first frame is not
    /// cleared at all.
    public func frame(gamepad: UInt8) throws {
        withMemory { raw in
            raw[Address.gamepad1] = gamepad
        }

        if isFirstFrame {
            isFirstFrame = false
            if let start = startFunction {
                _ = try start.invoke(on: &stack)
            }
        } else {
            let preserve = withMemory { raw in
                raw[Address.systemFlags] & SystemFlag.preserveFramebuffer
            }
            if preserve == 0 {
                withMemory { raw in
                    for index in 0..<Screen.framebufferSize {
                        raw[Address.framebuffer + index] = 0
                    }
                }
            }
        }

        _ = try updateFunction.invoke(on: &stack)
    }

    /// Runs `body` with the console's whole address space.
    public func withMemory<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        try memory.withUnsafeMutableBufferPointer(offset: 0, count: Screen.memorySize, body)
    }

    /// The four palette entries, as 0x00RRGGBB, read fresh because carts change
    /// them at run time to flash, fade, or invert.
    public func palette() -> (UInt32, UInt32, UInt32, UInt32) {
        withMemory { raw in
            (
                Bytes.readUInt32(raw, at: Address.palette),
                Bytes.readUInt32(raw, at: Address.palette + 4),
                Bytes.readUInt32(raw, at: Address.palette + 8),
                Bytes.readUInt32(raw, at: Address.palette + 12)
            )
        }
    }
}
