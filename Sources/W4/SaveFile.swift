import CPlaydate
import WASM4

/// A cart's 1024 bytes of save data, one file per cart in the application's
/// data directory.
///
/// Sideloading through play.date rewrites the bundle identifier, so a sideloaded
/// build does not share saves with one uploaded from the Simulator.
struct SaveFile {
    private var name = [CChar](repeating: 0, count: 64)

    /// Turns "carts/watris.wasm" into "watris.disk".
    mutating func use(cart: StaticString) {
        var bytes: [UInt8] = []
        cart.withUTF8Buffer { buffer in bytes = Array(buffer) }

        var start = 0
        for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "/") {
            start = index + 1
        }
        var end = bytes.count
        var index = bytes.count - 1
        while index >= start {
            if bytes[index] == UInt8(ascii: ".") {
                end = index
                break
            }
            index -= 1
        }

        var length = 0
        for position in start..<end where length < name.count - 8 {
            name[length] = CChar(bitPattern: bytes[position])
            length += 1
        }
        for byte in Array(".disk".utf8) where length < name.count - 1 {
            name[length] = CChar(bitPattern: byte)
            length += 1
        }
        name[length] = 0
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, on playdate: Playdate) -> Int {
        let file = playdate.file
        return name.withUnsafeBufferPointer { path in
            guard let handle = file.open(path.baseAddress, kFileReadData) else { return 0 }
            defer { _ = file.close(handle) }
            let read = file.read(handle, buffer.baseAddress, UInt32(buffer.count))
            return read > 0 ? Int(read) : 0
        }
    }

    func write(from buffer: UnsafeRawBufferPointer, on playdate: Playdate) -> Int {
        let file = playdate.file
        return name.withUnsafeBufferPointer { path in
            guard let handle = file.open(path.baseAddress, kFileWrite) else { return 0 }
            defer { _ = file.close(handle) }
            let written = file.write(
                handle, UnsafeMutableRawPointer(mutating: buffer.baseAddress),
                UInt32(buffer.count))
            return written > 0 ? Int(written) : 0
        }
    }
}
