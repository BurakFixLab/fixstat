import AVFoundation
import AppKit
import CoreAudio
import MacSensors

// Speakers, microphone and camera for the hardware check, shared by both interfaces.
// Main thread; state changes are reported through `onChange`.

// MARK: - Permissions

public enum MediaPermission {
    case unknown, granted, denied

    /// Camera / microphone permission. macOS 10.13 has no such permission: always granted.
    public static func request(_ type: AVMediaType, completion: @escaping (MediaPermission) -> Void) {
        guard #available(macOS 10.14, *) else {
            completion(.granted)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            completion(.granted)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: type) { granted in
                DispatchQueue.main.async { completion(granted ? .granted : .denied) }
            }
        default:
            completion(.denied)
        }
    }

    public static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Core Audio devices

public struct AudioDevice {
    public let name: String
    public let isBuiltIn: Bool
    public let volume: Float?
    public let muted: Bool?

    /// kAudioObjectPropertyElementMain (named so from macOS 12; 0 on every system).
    private static let mainElement = AudioObjectPropertyElement(0)

    public static func defaultDevice(input: Bool) -> AudioDevice? {
        var id = AudioObjectID(0)
        guard get(AudioObjectID(kAudioObjectSystemObject),
                  input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                  kAudioObjectPropertyScopeGlobal, &id), id != 0 else { return nil }
        guard let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        var transport: UInt32 = 0
        _ = get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        var volume: Float32 = 0
        let hasVolume = get(id, kAudioDevicePropertyVolumeScalar, scope, &volume, element: mainElement)
            || get(id, kAudioDevicePropertyVolumeScalar, scope, &volume, element: 1)
        var mute: UInt32 = 0
        let hasMute = get(id, kAudioDevicePropertyMute, scope, &mute, element: mainElement)
        return AudioDevice(name: name, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                           volume: hasVolume ? volume : nil, muted: hasMute ? mute != 0 : nil)
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: mainElement)
        let pointer = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        pointer.initialize(to: nil)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr,
              let value = pointer.pointee else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope, _ value: inout T,
                               element: AudioObjectPropertyElement = mainElement) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { bytes in
            guard let base = bytes.baseAddress else { return false }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, base) == noErr
        }
    }
}

// MARK: - Speakers

/// Sine tones on the left / right channel and a logarithmic sweep, rendered into a buffer
/// and played with AVAudioPlayerNode (AVAudioSourceNode needs macOS 10.15).
public final class TonePlayer {
    public enum Tone: CaseIterable, Hashable { case left, right, both, sweep }

    public private(set) var playing: Tone?
    public var onChange: (() -> Void)?
    private var engine: AVAudioEngine?
    private var stopTimer: Timer?

    public init() {}

    public static func name(_ tone: Tone) -> String {
        switch tone {
        case .left: return L("left")
        case .right: return L("right")
        case .both: return L("both")
        case .sweep: return L("sweep")
        }
    }

    public func play(_ tone: Tone) {
        stop()
        let engine = AVAudioEngine()
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = outputRate > 0 ? outputRate : 48_000
        let duration = tone == .sweep ? 6.0 : 1.5
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buffer = Self.render(tone, format: format, duration: duration) else { return }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        node.scheduleBuffer(buffer, completionHandler: nil)
        node.play()
        self.engine = engine
        playing = tone
        onChange?()
        let timer = Timer(timeInterval: duration + 0.1, repeats: false) { [weak self] _ in self?.stop() }
        RunLoop.main.add(timer, forMode: .common)
        stopTimer = timer
    }

    public func stop() {
        stopTimer?.invalidate()
        stopTimer = nil
        engine?.stop()
        engine = nil
        if playing != nil {
            playing = nil
            onChange?()
        }
    }

    private static func render(_ tone: Tone, format: AVAudioFormat, duration: Double) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let total = Int(duration * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(total)
        let left: Float = tone != .right ? 1 : 0
        let right: Float = tone != .left ? 1 : 0
        let fade = rate * 0.02
        var phase = 0.0
        for sample in 0..<total {
            let t = Double(sample) / rate
            let frequency = tone == .sweep ? 100 * pow(80, t / duration) : 1_000
            phase += 2 * .pi * frequency / rate
            if phase > 2 * .pi { phase -= 2 * .pi }
            let envelope = min(1, Double(sample) / fade, Double(total - sample) / fade)
            let value = Float(sin(phase) * 0.35 * envelope)
            channels[0][sample] = value * left
            channels[1][sample] = value * right
        }
        return buffer
    }
}

// MARK: - Microphone

/// Input level meter with a short recording that can be played back.
public final class MicrophoneLevel: @unchecked Sendable {
    public private(set) var permission = MediaPermission.unknown
    /// RMS level in dBFS.
    public private(set) var level: Float = -120
    /// Highest peak since the test started, dBFS.
    public private(set) var peak: Float = -120
    public private(set) var recording = false
    public private(set) var playingBack = false
    public var hasRecording: Bool { !samples.isEmpty }
    public var onChange: (() -> Void)?

    private var engine: AVAudioEngine?
    private var player: AVAudioEngine?
    private var samples: [Float] = []
    private var sampleRate = 48_000.0
    private var recordUntil: Date?

    public init() {}

    public func start() {
        MediaPermission.request(.audio) { [weak self] permission in
            guard let self else { return }
            self.permission = permission
            if permission == .granted { self.startEngine() }
            self.onChange?()
        }
    }

    private func startEngine() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let values = Array(UnsafeBufferPointer(start: channel, count: count))
            var sum: Float = 0
            var maximum: Float = 0
            for v in values {
                sum += v * v
                maximum = max(maximum, abs(v))
            }
            let rms = 10 * log10(max(sum / Float(max(count, 1)), 1e-12))
            let peak = 20 * log10(max(maximum, 1e-6))
            DispatchQueue.main.async { self?.update(rms: rms, peak: peak, values: values) }
        }
        do { try engine.start() } catch { return }
        self.engine = engine
    }

    private func update(rms: Float, peak: Float, values: [Float]) {
        level = rms
        if peak > self.peak { self.peak = peak }
        if let until = recordUntil {
            if Date() < until {
                samples += values
            } else {
                recordUntil = nil
                recording = false
            }
        }
        onChange?()
    }

    public func record(seconds: Double) {
        samples = []
        recordUntil = Date().addingTimeInterval(seconds)
        recording = true
        onChange?()
    }

    public func playBack() {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, value) in samples.enumerated() { channel[index] = value }
        // Stop listening while playing back, so the speakers do not feed the meter.
        stopEngine()
        let player = AVAudioEngine()
        let node = AVAudioPlayerNode()
        player.attach(node)
        player.connect(node, to: player.mainMixerNode, format: format)
        do { try player.start() } catch { startEngine(); return }
        self.player = player
        playingBack = true
        onChange?()
        node.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let meter = self else { return }
                meter.player?.stop()
                meter.player = nil
                meter.playingBack = false
                meter.startEngine()
                meter.onChange?()
            }
        }
        node.play()
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    public func stop() {
        stopEngine()
        player?.stop()
        player = nil
        playingBack = false
    }

    public var detail: String {
        ([AudioDevice.defaultDevice(input: true)?.name].compactMap { $0 }
            + [L("peak %@", Format.decibels(Double(peak), unit: "dBFS"))]).joined(separator: " · ")
    }
}

// MARK: - Camera

/// Camera session with a frame counter and the average brightness of recent frames.
public final class CameraCapture: @unchecked Sendable {
    public enum Permission { case unknown, granted, denied, noCamera }

    public private(set) var permission = Permission.unknown
    public private(set) var deviceName: String?
    public private(set) var resolution: String?
    public private(set) var frames = 0
    /// Average luma 0…1 of a recent frame.
    public private(set) var brightness: Double?
    public var onChange: (() -> Void)?

    public let session = AVCaptureSession()
    private let sampler = FrameSampler()
    private let queue = DispatchQueue(label: "FixStat.camera")
    private var configured = false

    public init() {}

    /// Asks for permission if needed and starts the session; `completion` runs when the
    /// permission is known.
    public func start(completion: (() -> Void)? = nil) {
        MediaPermission.request(.video) { [weak self] result in
            guard let self else { return }
            permission = result == .granted ? .granted : .denied
            if permission == .granted { configureAndRun() }
            onChange?()
            completion?()
        }
    }

    private func configureAndRun() {
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                permission = .noCamera
                return
            }
            deviceName = device.localizedName
            if let dimensions = CoreMediaFunctions.dimensions(device.activeFormat.formatDescription) {
                resolution = "\(dimensions.width) × \(dimensions.height)"
            }
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            sampler.onFrame = { [weak self] count, luma in
                DispatchQueue.main.async {
                    guard let camera = self else { return }
                    camera.frames = count
                    if let luma { camera.brightness = luma }
                    camera.onChange?()
                }
            }
            output.setSampleBufferDelegate(sampler, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            configured = true
        }
        let session = session
        queue.async { session.startRunning() }
    }

    public func stop() {
        let session = session
        queue.async { session.stopRunning() }
    }

    public var detail: String? {
        guard let deviceName, let brightness else { return nil }
        return [deviceName, resolution, L("average brightness %@", Format.percent(brightness * 100))]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Black image after a second of frames: covered lens, camera or cable.
    public var looksBlack: Bool { frames > 30 && (brightness ?? 1) < 0.03 }
}

/// Counts frames and measures the average luma of every 15th frame (Y plane, sparse).
private final class FrameSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFrame: ((Int, Double?) -> Void)?
    private var count = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        count += 1
        guard count % 15 == 1, let pixels = CoreMediaFunctions.imageBuffer(sampleBuffer) else {
            if count % 15 == 0 { onFrame?(count, nil) }
            return
        }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var samples = 0
        for y in Swift.stride(from: 0, to: height, by: 16) {
            for x in Swift.stride(from: 0, to: width, by: 16) {
                total += Int(bytes[y * stride + x])
                samples += 1
            }
        }
        onFrame?(count, samples > 0 ? Double(total) / Double(samples) / 255 : nil)
    }
}

/// CoreMedia C functions looked up at run time: on the x86_64 (10.13) slice the compiler
/// binds them to libswiftCoreMedia, which re-exports CoreMedia only on recent macOS.
enum CoreMediaFunctions {
    private typealias ImageBuffer = @convention(c) (CMSampleBuffer) -> Unmanaged<CVImageBuffer>?
    private typealias Dimensions = @convention(c) (CMFormatDescription) -> CMVideoDimensions

    private static let handle = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY)
    private static let imageBufferFunction: ImageBuffer? = symbol("CMSampleBufferGetImageBuffer")
    private static let dimensionsFunction: Dimensions? = symbol("CMVideoFormatDescriptionGetDimensions")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static func imageBuffer(_ sample: CMSampleBuffer) -> CVImageBuffer? {
        imageBufferFunction?(sample)?.takeUnretainedValue()
    }

    static func dimensions(_ description: CMFormatDescription) -> CMVideoDimensions? {
        dimensionsFunction?(description)
    }
}
