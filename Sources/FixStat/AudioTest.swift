import AVFoundation
import CoreAudio
import MacSensors
import SwiftUI
import FixStatCore

// MARK: - Speakers

@available(macOS 14.0, *)
struct SpeakerTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var generator = ToneGenerator()
    @State private var device = AudioDevice.defaultDevice(input: false)
    @State private var played: Set<ToneGenerator.Tone> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceLine
            HStack(spacing: 10) {
                toneButton("Left", "speaker.wave.1", .left)
                toneButton("Right", "speaker.wave.1", .right)
                toneButton("Both", "speaker.wave.2", .both)
                toneButton("Sweep", "waveform", .sweep)
                if generator.playing != nil {
                    Button("Stop") { generator.stop() }
                }
            }
        }
        .onDisappear { generator.stop() }
    }

    @ViewBuilder
    private var deviceLine: some View {
        if let device {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: device.name).font(.headline)
                if device.muted == true {
                    Label("Output is muted.", systemImage: "speaker.slash.fill")
                        .foregroundStyle(TemperatureColor.hot)
                } else if let volume = device.volume {
                    Text("Volume \(Format.percent(Double(volume) * 100))")
                        .foregroundStyle(volume < 0.25 ? AnyShapeStyle(TemperatureColor.hot) : AnyShapeStyle(.secondary))
                }
                if !device.isBuiltIn {
                    Label("This is not the built-in output. Unplug headphones or choose the internal speakers.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(TemperatureColor.hot)
                }
            }
            .font(.callout)
        }
    }

    private func toneButton(_ title: LocalizedStringKey, _ symbol: String, _ tone: ToneGenerator.Tone) -> some View {
        Button {
            device = AudioDevice.defaultDevice(input: false)
            generator.play(tone)
            played.insert(tone)
            let names = ToneGenerator.Tone.allCases.filter(played.contains).map(ToneGenerator.name)
            monitor.recordCheck(.speakers, detail: ([device?.name].compactMap { $0 } + names).joined(separator: " · "))
        } label: {
            Label(title, systemImage: generator.playing == tone ? "speaker.wave.3.fill" : symbol)
        }
        .controlSize(.large)
    }
}

/// Sine tones on the left / right channel and a logarithmic sweep.
@available(macOS 14.0, *)
@MainActor
@Observable
final class ToneGenerator {
    enum Tone: CaseIterable, Hashable { case left, right, both, sweep }

    private(set) var playing: Tone?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    static func name(_ tone: Tone) -> String {
        switch tone {
        case .left: String(localized: "left")
        case .right: String(localized: "right")
        case .both: String(localized: "both")
        case .sweep: String(localized: "sweep")
        }
    }

    func play(_ tone: Tone) {
        stop()
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate > 0
            ? engine.outputNode.outputFormat(forBus: 0).sampleRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let duration = tone == .sweep ? 6.0 : 1.5
        let state = ToneState(tone: tone, rate: rate, duration: duration)
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            state.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        self.engine = engine
        playing = tone
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.1))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel()
        engine?.stop()
        engine = nil
        playing = nil
    }
}

/// Render state, touched only by the audio thread.
@available(macOS 14.0, *)
private final class ToneState: @unchecked Sendable {
    let tone: ToneGenerator.Tone
    let rate: Double
    let total: Int
    var sample = 0
    var phase = 0.0

    init(tone: ToneGenerator.Tone, rate: Double, duration: Double) {
        self.tone = tone
        self.rate = rate
        self.total = Int(duration * rate)
    }

    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        let left = tone != .right ? 1.0 : 0.0
        let right = tone != .left ? 1.0 : 0.0
        let fade = rate * 0.02
        for frame in 0..<frames {
            var value = 0.0
            if sample < total {
                let t = Double(sample) / rate
                let frequency = tone == .sweep ? 100 * pow(80, t / (Double(total) / rate)) : 1_000
                phase += 2 * .pi * frequency / rate
                if phase > 2 * .pi { phase -= 2 * .pi }
                let envelope = min(1, Double(sample) / fade, Double(total - sample) / fade)
                value = sin(phase) * 0.35 * envelope
            }
            sample += 1
            for (channel, buffer) in buffers.enumerated() {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                data[frame] = Float(value * (channel == 0 ? left : right))
            }
        }
    }
}

// MARK: - Microphone

@available(macOS 14.0, *)
struct MicrophoneTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var meter = MicrophoneMeter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let device = AudioDevice.defaultDevice(input: true) {
                Text(verbatim: device.name).font(.headline)
            }
            switch meter.permission {
            case .denied:
                Label("FixStat has no microphone access. Allow it in System Settings › Privacy & Security › Microphone.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(TemperatureColor.hot)
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            default:
                VStack(alignment: .leading, spacing: 4) {
                    LevelBar(fraction: (Double(meter.level) + 60) / 60, color: TemperatureColor.cool, height: 12)
                        .frame(maxWidth: 480)
                    Text("Level \(Format.decibels(Double(meter.level), unit: "dBFS")) · peak \(Format.decibels(Double(meter.peak), unit: "dBFS"))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        meter.record(seconds: 4)
                    } label: {
                        Label(meter.recording ? "Recording…" : "Record 4 s", systemImage: "record.circle")
                    }
                    .disabled(meter.recording || meter.playingBack)
                    Button {
                        meter.playBack()
                    } label: {
                        Label("Play back", systemImage: "play.fill")
                    }
                    .disabled(!meter.hasRecording || meter.recording || meter.playingBack)
                }
            }
        }
        .task { await meter.start() }
        .onDisappear { meter.stop() }
        .onChange(of: meter.peak) { _, peak in
            guard peak > -120 else { return }
            let name = AudioDevice.defaultDevice(input: true)?.name
            monitor.recordCheck(.microphone, detail: ([name].compactMap { $0 }
                + [String(localized: "peak \(Format.decibels(Double(peak), unit: "dBFS"))")]).joined(separator: " · "))
        }
    }
}

@available(macOS 14.0, *)
@MainActor
@Observable
final class MicrophoneMeter {
    enum Permission { case unknown, granted, denied }

    private(set) var permission = Permission.unknown
    /// RMS level in dBFS.
    private(set) var level: Float = -120
    /// Highest peak since the test started, dBFS.
    private(set) var peak: Float = -120
    private(set) var recording = false
    private(set) var playingBack = false
    var hasRecording: Bool { !samples.isEmpty }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioEngine?
    @ObservationIgnored private var samples: [Float] = []
    @ObservationIgnored private var sampleRate = 48_000.0
    @ObservationIgnored private var recordUntil: Date?

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = .granted
        case .notDetermined:
            permission = await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        default: permission = .denied
        }
        guard permission == .granted else { return }
        startEngine()
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
            Task { @MainActor in self?.update(rms: rms, peak: peak, values: values) }
        }
        do { try engine.start() } catch { return }
        self.engine = engine
    }

    private func update(rms: Float, peak: Float, values: [Float]) {
        level = rms
        if peak > self.peak { self.peak = peak }
        if let until = recordUntil {
            if Date() < until { samples += values } else { recordUntil = nil; recording = false }
        }
    }

    func record(seconds: Double) {
        samples = []
        recordUntil = Date().addingTimeInterval(seconds)
        recording = true
    }

    func playBack() {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        // Stop listening while playing back, so the speakers do not feed the meter.
        stopEngine()
        let player = AVAudioEngine()
        let node = AVAudioPlayerNode()
        player.attach(node)
        player.connect(node, to: player.mainMixerNode, format: format)
        do { try player.start() } catch { startEngine(); return }
        self.player = player
        playingBack = true
        node.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self?.player?.stop()
                self?.player = nil
                self?.playingBack = false
                self?.startEngine()
            }
        }
        node.play()
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    func stop() {
        stopEngine()
        player?.stop()
        player = nil
        playingBack = false
    }
}

// MARK: - Core Audio devices

@available(macOS 14.0, *)
struct AudioDevice {
    let name: String
    let isBuiltIn: Bool
    let volume: Float?
    let muted: Bool?

    static func defaultDevice(input: Bool) -> AudioDevice? {
        var id = AudioObjectID(0)
        guard get(AudioObjectID(kAudioObjectSystemObject),
                  input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                  kAudioObjectPropertyScopeGlobal, &id), id != 0 else { return nil }
        guard let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        var transport: UInt32 = 0
        _ = get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        var volume: Float32 = 0
        let hasVolume = get(id, kAudioDevicePropertyVolumeScalar, scope, &volume, element: kAudioObjectPropertyElementMain)
            || get(id, kAudioDevicePropertyVolumeScalar, scope, &volume, element: 1)
        var mute: UInt32 = 0
        let hasMute = get(id, kAudioDevicePropertyMute, scope, &mute, element: kAudioObjectPropertyElementMain)
        return AudioDevice(name: name, isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                           volume: hasVolume ? volume : nil, muted: hasMute ? mute != 0 : nil)
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let pointer = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        pointer.initialize(to: nil)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr,
              let value = pointer.pointee else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope, _ value: inout T,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}
