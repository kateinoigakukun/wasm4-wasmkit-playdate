import WasmKit

extension Console {
    /// Registers the `env` module a WASM-4 cart imports.
    ///
    /// Defining more than a given cart imports is harmless; carts only link
    /// what they call. Across the published library `rect` is the most used
    /// drawing call and `traceUtf16` the least, used by two carts.
    static func defineHostFunctions(
        into imports: inout Imports, store: Store, memory: Memory, peripherals: Peripherals
    ) {
        // The base address is taken once rather than captured as the `Memory`
        // itself, and for two reasons. A `Memory` holds the store that owns
        // these very closures, so capturing one is a reference cycle: the whole
        // interpreter state of every cart ever loaded would stay allocated, and
        // on the device that ends as a failed allocation, which in Swift is a
        // trap. It also spares each of a cart's drawing calls the handle
        // indirection.
        //
        // The address is stable for exactly as long as it is used: the console
        // declares its memory `min: 1, max: 1`, so `memory.grow` always fails
        // and the allocation is never moved, and a host function can only run
        // while a frame is executing, which is to say while the `Console`
        // holding this memory is alive.
        let base = memory.withUnsafeMutableBufferPointer(offset: 0, count: Screen.memorySize) {
            $0.baseAddress!
        }

        @inline(__always)
        func withMemory<T>(_ body: (UnsafeMutableRawBufferPointer) -> T) -> T {
            body(UnsafeMutableRawBufferPointer(start: base, count: Screen.memorySize))
        }

        /// Registers a drawing call.
        ///
        /// These take the unboxed host function form: a cart makes tens to
        /// thousands of them per frame, and the array the ordinary form
        /// allocates for the parameters costs more on this device than the
        /// drawing it carries.
        func define(
            _ name: String, _ parameterCount: Int,
            _ body: @escaping (UnsafeBufferPointer<Value>) -> Void
        ) {
            let function = Function(
                store: store,
                parameters: Array(repeating: .i32, count: parameterCount),
                results: [],
                raw: { _, arguments, _ in body(arguments) }
            )
            imports.define(module: "env", name: name, function)
        }

        @inline(__always)
        func int(_ arguments: UnsafeBufferPointer<Value>, _ index: Int) -> Int {
            Int(Int32(bitPattern: arguments[index].i32))
        }

        @inline(__always)
        func int(_ arguments: [Value], _ index: Int) -> Int {
            Int(Int32(bitPattern: arguments[index].i32))
        }

        define("rect", 4) { arguments in
            withMemory { raw in
                Framebuffer.rect(
                    raw, x: int(arguments, 0), y: int(arguments, 1),
                    width: int(arguments, 2), height: int(arguments, 3))
            }
        }

        define("hline", 3) { arguments in
            withMemory { raw in
                Framebuffer.hline(
                    raw, x: int(arguments, 0), y: int(arguments, 1), length: int(arguments, 2))
            }
        }

        define("vline", 3) { arguments in
            withMemory { raw in
                Framebuffer.vline(
                    raw, x: int(arguments, 0), y: int(arguments, 1), length: int(arguments, 2))
            }
        }

        define("line", 4) { arguments in
            withMemory { raw in
                Framebuffer.line(
                    raw, x1: int(arguments, 0), y1: int(arguments, 1),
                    x2: int(arguments, 2), y2: int(arguments, 3))
            }
        }

        /// Views the cart's address space starting at `offset`, which clamps
        /// every sprite read to the 64 KiB window.
        @inline(__always)
        func spriteView(_ raw: UnsafeMutableRawBufferPointer, at offset: Int)
            -> UnsafeRawBufferPointer?
        {
            guard offset >= 0, offset < Screen.memorySize, let base = raw.baseAddress else {
                return nil
            }
            return UnsafeRawBufferPointer(
                start: base + offset, count: Screen.memorySize - offset)
        }

        define("blit", 6) { arguments in
            withMemory { raw in
                guard let sprite = spriteView(raw, at: int(arguments, 0)) else { return }
                let width = int(arguments, 3)
                Framebuffer.blit(
                    raw, sprite: sprite,
                    dstX: int(arguments, 1), dstY: int(arguments, 2),
                    width: width, height: int(arguments, 4),
                    srcX: 0, srcY: 0, stride: width, flags: int(arguments, 5))
            }
        }

        define("blitSub", 9) { arguments in
            withMemory { raw in
                guard let sprite = spriteView(raw, at: int(arguments, 0)) else { return }
                Framebuffer.blit(
                    raw, sprite: sprite,
                    dstX: int(arguments, 1), dstY: int(arguments, 2),
                    width: int(arguments, 3), height: int(arguments, 4),
                    srcX: int(arguments, 5), srcY: int(arguments, 6),
                    stride: int(arguments, 7), flags: int(arguments, 8))
            }
        }

        define("oval", 4) { arguments in
            withMemory { raw in
                Framebuffer.oval(
                    raw, x: int(arguments, 0), y: int(arguments, 1),
                    width: int(arguments, 2), height: int(arguments, 3))
            }
        }

        /// Reads a NUL-terminated byte string out of the cart's memory.
        func latin1(_ raw: UnsafeMutableRawBufferPointer, at offset: Int, limit: Int) -> [UInt16] {
            var characters: [UInt16] = []
            var index = offset
            while index < Screen.memorySize && characters.count < limit {
                let byte = raw[index]
                if byte == 0 { break }
                characters.append(UInt16(byte))
                index += 1
            }
            return characters
        }

        define("text", 3) { arguments in
            withMemory { raw in
                let characters = latin1(raw, at: int(arguments, 0), limit: Screen.memorySize)
                Framebuffer.text(
                    raw, characters: characters, x: int(arguments, 1), y: int(arguments, 2))
            }
        }

        define("textUtf8", 4) { arguments in
            withMemory { raw in
                // Despite the name this is a run of single bytes, not decoded
                // UTF-8; the reference runtime treats each byte as one glyph.
                let characters = latin1(
                    raw, at: int(arguments, 0), limit: max(0, int(arguments, 1)))
                Framebuffer.text(
                    raw, characters: characters, x: int(arguments, 2), y: int(arguments, 3))
            }
        }

        define("textUtf16", 4) { arguments in
            withMemory { raw in
                let offset = int(arguments, 0)
                let byteLength = max(0, int(arguments, 1))
                var characters: [UInt16] = []
                var index = offset
                while index + 1 < Screen.memorySize && index < offset + byteLength {
                    let unit = Bytes.readUInt16(raw, at: index)
                    if unit == 0 { break }
                    characters.append(unit)
                    index += 2
                }
                Framebuffer.text(
                    raw, characters: characters, x: int(arguments, 2), y: int(arguments, 3))
            }
        }
        define("tone", 4) { arguments in
            peripherals.tone?(
                arguments[0].i32, arguments[1].i32, arguments[2].i32, arguments[3].i32)
        }
        define("trace", 1) { _ in }
        define("traceUtf8", 2) { _ in }
        define("traceUtf16", 2) { _ in }
        define("tracef", 2) { _ in }

        // Save data. These return a byte count, so they cannot use `define`.
        let read = Function(store: store, parameters: [.i32, .i32], results: [.i32]) { _, arguments in
            guard let diskRead = peripherals.diskRead else { return [.i32(0)] }
            let offset = int(arguments, 0)
            let size = min(max(0, int(arguments, 1)), Peripherals.diskSize)
            guard offset >= 0, offset + size <= Screen.memorySize else { return [.i32(0)] }
            let count = withMemory { raw -> Int in
                let destination = UnsafeMutableRawBufferPointer(
                    start: raw.baseAddress! + offset, count: size)
                return diskRead(destination)
            }
            return [.i32(UInt32(max(0, count)))]
        }
        imports.define(module: "env", name: "diskr", read)

        let write = Function(store: store, parameters: [.i32, .i32], results: [.i32]) { _, arguments in
            guard let diskWrite = peripherals.diskWrite else { return [.i32(0)] }
            let offset = int(arguments, 0)
            // diskw truncates to the disk size and replaces everything.
            let size = min(max(0, int(arguments, 1)), Peripherals.diskSize)
            guard offset >= 0, offset + size <= Screen.memorySize else { return [.i32(0)] }
            let count = withMemory { raw -> Int in
                let source = UnsafeRawBufferPointer(
                    start: raw.baseAddress! + offset, count: size)
                return diskWrite(source)
            }
            return [.i32(UInt32(max(0, count)))]
        }
        imports.define(module: "env", name: "diskw", write)
    }
}
