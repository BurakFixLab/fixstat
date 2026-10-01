import Foundation
@preconcurrency import Metal

/// Shared stop signal for load threads.
public final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    public init() {}

    public var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }
}

/// Synthetic loads used to heat specific parts of the SoC / board
/// (`sensormap` load tests and the app's post-repair test).
public enum LoadGenerator {
    /// Starts `threads` busy threads doing floating point work until `flag` is set.
    public static func cpu(threads: Int, flag: StopFlag) {
        for _ in 0..<threads {
            let thread = Thread {
                var x = 1.000001
                while !flag.isStopped {
                    for _ in 0..<2_000_000 {
                        x = x * 1.0000001 + 0.0000001
                        if x > 2 { x = 1.000001 }
                    }
                }
                // Keep the result observable so the loop is not optimised away.
                if x == 0 { print(x) }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    static let metalSource = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void burn(device float *buffer [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float x = buffer[id];
            for (int i = 0; i < 2048; i++) {
                x = fma(x, 1.000001f, 0.000001f);
                x = sin(x) * cos(x) + x * 0.5f;
            }
            buffer[id] = x;
        }
        """

    /// Runs a Metal compute kernel in a loop until `flag` is set.
    /// Returns an error description if Metal is not available.
    @discardableResult
    public static func gpu(flag: StopFlag) -> String? {
        guard let device = MTLCreateSystemDefaultDevice() else { return "no Metal device" }
        do {
            let library = try device.makeLibrary(source: metalSource, options: nil)
            guard let function = library.makeFunction(name: "burn"),
                  let queue = device.makeCommandQueue() else { return "Metal setup failed" }
            let pipeline = try device.makeComputePipelineState(function: function)
            let count = 1 << 20
            guard let buffer = device.makeBuffer(length: count * MemoryLayout<Float>.stride,
                                                 options: .storageModePrivate) else { return "buffer allocation failed" }
            let thread = Thread {
                while !flag.isStopped {
                    guard let commands = queue.makeCommandBuffer(),
                          let encoder = commands.makeComputeCommandEncoder() else { break }
                    encoder.setComputePipelineState(pipeline)
                    encoder.setBuffer(buffer, offset: 0, index: 0)
                    // Whole threadgroups: dispatchThreads needs non-uniform threadgroup support,
                    // which older Intel GPUs (e.g. HD 5000) lack.
                    let width = pipeline.threadExecutionWidth
                    encoder.dispatchThreadgroups(MTLSize(width: count / width, height: 1, depth: 1),
                                                 threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
                    encoder.endEncoding()
                    commands.commit()
                    commands.waitUntilCompleted()
                }
            }
            // Same priority as the CPU load threads; with a lower one the feeding
            // thread starves under full CPU load and the GPU idles between dispatches.
            thread.qualityOfService = .userInteractive
            thread.start()
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// Writes and reads back a scratch file with the page cache disabled until
    /// `flag` is set. The file is removed afterwards.
    public static func ssd(directory: URL, fileSize: Int, flag: StopFlag) {
        let thread = Thread {
            let url = directory.appendingPathComponent("sensormap-ssd-\(getpid()).bin")
            let chunkSize = 8 << 20
            let chunk = [UInt8](repeating: 0xA5, count: chunkSize)
            var readBuffer = [UInt8](repeating: 0, count: chunkSize)
            defer { unlink(url.path) }
            while !flag.isStopped {
                // Write pass.
                let fd = open(url.path, O_CREAT | O_TRUNC | O_WRONLY, 0o600)
                guard fd >= 0 else { return }
                _ = fcntl(fd, F_NOCACHE, 1)
                var written = 0
                while written < fileSize, !flag.isStopped {
                    let n = chunk.withUnsafeBytes { write(fd, $0.baseAddress, chunkSize) }
                    if n <= 0 { break }
                    written += n
                }
                fsync(fd)
                close(fd)
                // Read pass.
                let rfd = open(url.path, O_RDONLY)
                guard rfd >= 0 else { return }
                _ = fcntl(rfd, F_NOCACHE, 1)
                while !flag.isStopped {
                    let n = readBuffer.withUnsafeMutableBytes { read(rfd, $0.baseAddress, chunkSize) }
                    if n <= 0 { break }
                }
                close(rfd)
            }
        }
        thread.start()
    }
}
