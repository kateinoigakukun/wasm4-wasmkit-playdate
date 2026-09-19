// Runs every cart in a directory headlessly for a fixed number of frames.
//
// This is the only automated check that puts the interpreter, the host
// functions and real third-party carts together, and it needs neither a
// Playdate nor a display. A cart that traps, fails to instantiate, or draws
// nothing at all shows up here rather than on camera.
//
// It deliberately does not compare pixels against anything; what it checks is
// that real carts load, keep running, and draw something.

import WASM4
import WasmKit

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

let framesPerCart = 120

guard CommandLine.arguments.count > 1 else {
    fputs("usage: cartrun <directory-of-carts>\n", stderr)
    exit(2)
}
let directory = CommandLine.arguments[1]
/// When given, a 160x160 one-bit image of each cart's final frame is written
/// here as a binary PGM. `tools/covers/generate.sh` turns those into the PNGs
/// the shelf displays. Producing the art from this runtime rather than copying
/// screenshots means the covers look exactly like the games do on the device.
let coverDirectory: String? = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
/// Which reduction the covers use. Defaults to the same one the device uses, so
/// the covers look like the games do. Pass "dither" to compare against the
/// dithered one.
let coverPolicy: Dither.Policy =
    CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "dither"
    ? .stretched : .threshold

/// Applies the same reduction the device uses, and writes a binary PGM.
func writeCover(_ console: Console, to path: String, policy: Dither.Policy) {
    // Which colours this frame actually uses, so that a two-colour screen comes
    // out as solid black and white rather than two dither patterns.
    // Coverage, not mere presence: a colour used for a handful of stray pixels
    // would otherwise consume a whole rank and push a heavily used colour into
    // a dither pattern. ZxZ's title screen does exactly that -- six pixels of
    // one colour were enough to break up all of its text.
    var counts = [0, 0, 0, 0]
    console.withMemory { raw in
        for index in 0..<Screen.framebufferSize {
            let byte = raw[Address.framebuffer + index]
            counts[Int(byte & 3)] += 1
            counts[Int((byte >> 2) & 3)] += 1
            counts[Int((byte >> 4) & 3)] += 1
            counts[Int((byte >> 6) & 3)] += 1
        }
    }
    let minimum = (Screen.width * Screen.height) / 200  // half a per cent
    let used = counts.map { $0 >= minimum }
    let palette = console.palette()
    let levels = Dither.levels(palette: palette, policy: policy, coverage: counts)
    var pixels = [UInt8](repeating: 0, count: Screen.width * Screen.height)

    console.withMemory { raw in
        for y in 0..<Screen.height {
            let row = Address.framebuffer + ((Screen.width * y) >> 2)
            for x in 0..<Screen.width {
                let colour = Int((raw[row + (x >> 2)] >> UInt8((x & 3) << 1)) & 0x3)
                let threshold = Dither.thresholds[(y & 7) * 8 + (x & 7)]
                pixels[y * Screen.width + x] = levels[colour] > threshold ? 255 : 0
            }
        }
    }

    // Also emit the console's own four-level picture beside the one-bit one, so
    // the two can be compared when something looks wrong on screen: it
    // distinguishes a drawing bug from the dither.
    if path.hasSuffix(".pgm") {
        var levelsOnly = [UInt8](repeating: 0, count: Screen.width * Screen.height)
        console.withMemory { raw in
            for y in 0..<Screen.height {
                let row = Address.framebuffer + ((Screen.width * y) >> 2)
                for x in 0..<Screen.width {
                    let colour = Int((raw[row + (x >> 2)] >> UInt8((x & 3) << 1)) & 0x3)
                    levelsOnly[y * Screen.width + x] = UInt8(colour * 85)
                }
            }
        }
        let rawPath = String(path.dropLast(4)) + "-levels.pgm"
        if let rawFile = fopen(rawPath, "wb") {
            let header = "P5\n\(Screen.width) \(Screen.height)\n255\n"
            _ = header.withCString { fputs($0, rawFile) }
            _ = levelsOnly.withUnsafeBytes { fwrite($0.baseAddress, 1, levelsOnly.count, rawFile) }
            fclose(rawFile)
        }
    }

    if getenv("W4_DIAG") != nil {
        let lumas = [
            Dither.luma(palette.0), Dither.luma(palette.1),
            Dither.luma(palette.2), Dither.luma(palette.3),
        ]
        print("      counts \(counts) used \(used) luma \(lumas) -> \(levels)")
    }

    guard let file = fopen(path, "wb") else { return }
    defer { fclose(file) }
    let header = "P5\n\(Screen.width) \(Screen.height)\n255\n"
    _ = header.withCString { fputs($0, file) }
    _ = pixels.withUnsafeBytes { fwrite($0.baseAddress, 1, pixels.count, file) }
}

func listCarts(in directory: String) -> [String] {
    guard let handle = opendir(directory) else { return [] }
    defer { closedir(handle) }

    var names: [String] = []
    while let entry = readdir(handle) {
        var nameBytes: [CChar] = []
        withUnsafeBytes(of: entry.pointee.d_name) { raw in
            for byte in raw.bindMemory(to: CChar.self) {
                if byte == 0 { break }
                nameBytes.append(byte)
            }
        }
        nameBytes.append(0)
        let name = String(decoding: nameBytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if name.hasSuffix(".wasm") { names.append(name) }
    }
    return names.sorted()
}

func read(path: String) -> [UInt8]? {
    guard let file = fopen(path, "rb") else { return nil }
    defer { fclose(file) }
    fseek(file, 0, SEEK_END)
    let size = ftell(file)
    fseek(file, 0, SEEK_SET)
    guard size > 0 else { return nil }

    var bytes = [UInt8](repeating: 0, count: size)
    let read = bytes.withUnsafeMutableBytes { fread($0.baseAddress, 1, size, file) }
    return read == size ? bytes : nil
}

/// Counts pixels that are not colour 0, as a crude check that a cart drew
/// something rather than sitting on a blank screen.
func inkedPixels(_ console: Console) -> Int {
    console.withMemory { raw in
        var count = 0
        for index in 0..<Screen.framebufferSize {
            let byte = raw[Address.framebuffer + index]
            if byte != 0 {
                for shift in stride(from: 0, to: 8, by: 2) where (byte >> UInt8(shift)) & 3 != 0 {
                    count += 1
                }
            }
        }
        return count
    }
}

let carts = listCarts(in: directory)
guard !carts.isEmpty else {
    fputs("no carts found in \(directory)\n", stderr)
    exit(1)
}

func run(carts: [String], in directory: String, policy: Dither.Policy) -> Int {
    var failures = 0
    let engine = Engine(
        configuration: EngineConfiguration(threadingModel: .token, stackSize: 64 * 1024))

    for name in carts {
        let path = directory + "/" + name
        guard let bytes = read(path: path) else {
            print("FAIL \(name): could not be read")
            failures += 1
            continue
        }

        do {
            let console = try Console(cart: bytes, engine: engine)

            // A RAM-backed disk, so carts that save and reload exercise that path.
            var disk = [UInt8](repeating: 0, count: Peripherals.diskSize)
            var diskUsed = 0
            var tones = 0
            console.peripherals.tone = { _, _, _, _ in tones += 1 }
            console.peripherals.diskRead = { buffer in
                let count = min(buffer.count, diskUsed)
                for index in 0..<count { buffer[index] = disk[index] }
                return count
            }
            console.peripherals.diskWrite = { buffer in
                let count = min(buffer.count, Peripherals.diskSize)
                for index in 0..<count { disk[index] = buffer[index] }
                diskUsed = count
                return count
            }

            // Hold a direction and a button down so carts that wait for input make
            // progress rather than sitting on a title screen.
            for frame in 0..<framesPerCart {
                let gamepad: UInt8 = frame % 20 < 10 ? 0x01 : 0x20
                try console.frame(gamepad: gamepad)
            }

            if let coverDirectory {
                let stem = String(name.dropLast(5))  // drop ".wasm"
                writeCover(console, to: coverDirectory + "/" + stem + ".pgm", policy: policy)
            }

            let inked = inkedPixels(console)
            let status = inked > 0 ? "ok  " : "BLANK"
            print("\(status) \(name): \(inked) pixels drawn, \(tones) tones, \(diskUsed) bytes saved")
            if inked == 0 { failures += 1 }
        } catch {
            print("FAIL \(name): \(error)")
            failures += 1
        }
    }
    return failures
}

let failures = run(carts: carts, in: directory, policy: coverPolicy)

print("")
if failures == 0 {
    print("PASS: \(carts.count) carts each ran \(framesPerCart) frames and drew something")
} else {
    print("FAIL: \(failures) of \(carts.count) carts had problems")
    exit(1)
}
