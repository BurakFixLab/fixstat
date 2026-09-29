import Darwin
import Foundation

// fixstat-diskscan — read-only surface scan of a whole disk.
//
// Runs as root (started by FixStat through the macOS administrator prompt) because
// raw disk devices are not readable by normal users. It only ever opens the device
// with O_RDONLY; nothing is written to the disk.
//
//   fixstat-diskscan --device /dev/rdiskN --size BYTES --out FILE --cancel FILE
//
// Progress is written to --out as JSON lines; the scan stops when --cancel exists.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fixstat-diskscan: \(message)\n".utf8))
    exit(2)
}

var device = "", out = "", cancel = ""
var size: Int64 = 0
var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--device": device = iterator.next() ?? ""
    case "--size": size = Int64(iterator.next() ?? "") ?? 0
    case "--out": out = iterator.next() ?? ""
    case "--cancel": cancel = iterator.next() ?? ""
    default: fail("unknown option \(argument)")
    }
}
// Only whole raw disks, e.g. /dev/rdisk0.
guard device.range(of: #"^/dev/rdisk[0-9]+$"#, options: .regularExpression) != nil else { fail("invalid device") }
guard size > 0, !out.isEmpty, !cancel.isEmpty else { fail("missing arguments") }

let fd = open(device, O_RDONLY)
guard fd >= 0 else { fail("cannot open \(device): errno \(errno)") }
_ = fcntl(fd, F_NOCACHE, 1)

umask(0o022)
guard let output = fopen(out, "w") else { fail("cannot write \(out)") }
setvbuf(output, nil, _IOLBF, 0)
func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    fputs(String(decoding: data, as: UTF8.self) + "\n", output)
}

let chunk = 8 << 20
let probe = 256 << 10 // granularity used to localize an error inside a failing chunk
var buffer: UnsafeMutableRawPointer?
guard posix_memalign(&buffer, 16384, chunk) == 0, let buffer else { fail("out of memory") }

emit(["type": "start", "device": device, "size": size, "chunk": chunk])
let start = Date()
var offset: Int64 = 0
var cancelled = false
while offset < size {
    if access(cancel, F_OK) == 0 { cancelled = true; break }
    let length = Int(min(Int64(chunk), size - offset))
    let t0 = Date()
    let n = pread(fd, buffer, length, off_t(offset))
    let ms = Date().timeIntervalSince(t0) * 1000
    if n == length {
        emit(["type": "chunk", "offset": offset, "length": length, "ms": ms])
    } else {
        // Re-read in small pieces to find the unreadable ranges.
        var badBytes = 0
        var sub: Int64 = 0
        while sub < Int64(length) {
            let piece = Int(min(Int64(probe), Int64(length) - sub))
            if pread(fd, buffer, piece, off_t(offset + sub)) != piece {
                badBytes += piece
                emit(["type": "error", "offset": offset + sub, "length": piece, "errno": Int(errno)])
            }
            sub += Int64(piece)
        }
        emit(["type": "chunk", "offset": offset, "length": length, "ms": Date().timeIntervalSince(t0) * 1000,
              "bad": badBytes])
    }
    offset += Int64(length)
}
emit(["type": "end", "bytes": offset, "seconds": Date().timeIntervalSince(start), "cancelled": cancelled])
fclose(output)
close(fd)
