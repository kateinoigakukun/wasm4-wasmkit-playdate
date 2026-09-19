/// The console's memory layout and the little-endian accessors for it.
///
/// Deliberately free of any WebAssembly dependency: the drawing code needs only
/// these, so anything that reads a framebuffer can do it without an
/// interpreter.

/// Fixed addresses inside the console's 64 KiB of memory.
///
/// WASM-4 does not pass state to a cart; the cart and the host share one flat
/// address space, and everything from the palette to the screen lives at a
/// documented offset within it.
public enum Address {
    public static let palette = 0x0004
    public static let drawColors = 0x0014
    public static let gamepad1 = 0x0016
    public static let mouseX = 0x001a
    public static let mouseY = 0x001c
    public static let mouseButtons = 0x001e
    public static let systemFlags = 0x001f
    public static let netplay = 0x0020
    public static let framebuffer = 0x00a0
}

public enum Screen {
    public static let width = 160
    public static let height = 160
    /// 160x160 pixels at 2 bits each.
    public static let framebufferSize = 6400
    /// One WebAssembly page. The cart imports this; it does not own it.
    public static let memorySize = 65536
}

public enum SystemFlag {
    public static let preserveFramebuffer: UInt8 = 1
    public static let hideGamepadOverlay: UInt8 = 2
}

/// Little-endian reads and writes into the shared address space.
public enum Bytes {
    @inline(__always)
    public static func readUInt32(_ raw: UnsafeMutableRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(raw[offset]) | (UInt32(raw[offset + 1]) << 8) | (UInt32(raw[offset + 2]) << 16)
            | (UInt32(raw[offset + 3]) << 24)
    }

    @inline(__always)
    public static func writeUInt32(
        _ raw: UnsafeMutableRawBufferPointer, at offset: Int, _ value: UInt32
    ) {
        raw[offset] = UInt8(value & 0xFF)
        raw[offset + 1] = UInt8((value >> 8) & 0xFF)
        raw[offset + 2] = UInt8((value >> 16) & 0xFF)
        raw[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    @inline(__always)
    public static func readUInt16(_ raw: UnsafeMutableRawBufferPointer, at offset: Int) -> UInt16 {
        UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
    }

    @inline(__always)
    public static func writeUInt16(
        _ raw: UnsafeMutableRawBufferPointer, at offset: Int, _ value: UInt16
    ) {
        raw[offset] = UInt8(value & 0xFF)
        raw[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
}
