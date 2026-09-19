import CPlaydate

/// The Playdate API, and the handful of conveniences built on it.
///
/// The firmware hands over a struct of function pointers at `kEventInit`; every
/// OS call goes through it and nothing is statically linked. Wrapping it in a
/// value that gets passed around keeps the pointer out of global scope.
struct Playdate {
    let api: UnsafeMutablePointer<PlaydateAPI>

    var graphics: playdate_graphics { api.pointee.graphics.pointee }
    var system: playdate_sys { api.pointee.system.pointee }
    var file: playdate_file { api.pointee.file.pointee }
    var display: playdate_display { api.pointee.display.pointee }

    func log(_ message: StaticString) {
        message.withUTF8Buffer { buffer in
            w4_log(UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self))
        }
    }

    func draw(_ text: StaticString, x: Int32, y: Int32) {
        text.withUTF8Buffer { buffer in
            _ = graphics.drawText(buffer.baseAddress, buffer.count, kUTF8Encoding, x, y)
        }
    }

    /// Draws a label followed by a decimal number. Formatting through `String`
    /// would pull in machinery this binary does not otherwise need.
    func draw(_ label: StaticString, value: UInt32, x: Int32, y: Int32) {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = 0

        label.withUTF8Buffer { bytes in
            for byte in bytes where length < buffer.count - 12 {
                buffer[length] = CChar(bitPattern: byte)
                length += 1
            }
        }

        var digits = [CChar](repeating: 0, count: 12)
        var digitCount = 0
        var remaining = value
        repeat {
            digits[digitCount] = CChar(48 + Int8(remaining % 10))
            digitCount += 1
            remaining /= 10
        } while remaining > 0
        while digitCount > 0 {
            digitCount -= 1
            buffer[length] = digits[digitCount]
            length += 1
        }

        buffer.withUnsafeBufferPointer { pointer in
            _ = graphics.drawText(pointer.baseAddress, length, kUTF8Encoding, x, y)
        }
    }

    /// Reads a file bundled inside the .pdx. `kFileRead` alone, not
    /// `kFileReadData`: the combined form shadows the bundle with the data
    /// directory and slows down as that directory fills.
    func readBundledFile(at path: StaticString, limit: Int) -> [UInt8]? {
        path.withUTF8Buffer { pathBytes -> [UInt8]? in
            let name = UnsafeRawPointer(pathBytes.baseAddress!).assumingMemoryBound(to: CChar.self)

            var status = FileStat()
            guard file.stat(name, &status) == 0 else {
                log("w4: file not found")
                return nil
            }
            let size = Int(status.size)
            guard size > 0, size <= limit else {
                log("w4: file size out of range")
                return nil
            }

            guard let handle = file.open(name, kFileRead) else {
                log("w4: file could not be opened")
                return nil
            }
            defer { _ = file.close(handle) }

            // One bulk read: per-open overhead dominates; throughput does not.
            var bytes = [UInt8](repeating: 0, count: size)
            let read = bytes.withUnsafeMutableBytes { buffer in
                file.read(handle, buffer.baseAddress, UInt32(size))
            }
            guard read == Int32(size) else {
                log("w4: file read was short")
                return nil
            }
            return bytes
        }
    }
}

extension PDButtons {
    /// `rawValue` is imported as `UInt8` for the device, which is built with
    /// -fshort-enums, and as `UInt32` for the host. Normalising here keeps the
    /// rest of the application free of that difference.
    @inline(__always)
    var bits: UInt32 { UInt32(truncatingIfNeeded: rawValue) }
}
