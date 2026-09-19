/// The seam between the console and its host.
///
/// Drawing needs nothing from the host; sound and save data do. Reaching them
/// through closures keeps the console free of any Playdate dependency. A
/// reference type because host functions are registered during `Console.init`,
/// before the host can install anything.
public final class Peripherals {
    /// `tone(frequency, duration, volume, flags)`.
    public var tone: ((UInt32, UInt32, UInt32, UInt32) -> Void)?
    /// Fills the buffer from save data and returns the number of bytes read.
    public var diskRead: ((UnsafeMutableRawBufferPointer) -> Int)?
    /// Persists the buffer and returns the number of bytes written.
    public var diskWrite: ((UnsafeRawBufferPointer) -> Int)?
    /// Receives `trace` output. Nil discards it, which is the usual case.
    public var trace: ((UnsafeRawBufferPointer) -> Void)?

    public init() {}

    /// WASM-4 caps save data at 1024 bytes and `diskw` replaces all of it.
    public static let diskSize = 1024
}
