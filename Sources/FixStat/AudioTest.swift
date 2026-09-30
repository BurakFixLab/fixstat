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

/// SwiftUI view of the core `TonePlayer`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class ToneGenerator {
    typealias Tone = TonePlayer.Tone

    private(set) var playing: Tone?
    @ObservationIgnored private let player = TonePlayer()

    init() {
        player.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    private func sync() {
        if player.playing != playing { playing = player.playing }
    }

    static func name(_ tone: Tone) -> String { TonePlayer.name(tone) }
    func play(_ tone: Tone) { player.play(tone) }
    func stop() { player.stop() }
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
                Button("Open System Settings") { MediaPermission.openSettings("Privacy_Microphone") }
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
            monitor.recordCheck(.microphone, detail: meter.detail)
        }
    }
}

/// SwiftUI view of the core `MicrophoneLevel`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class MicrophoneMeter {
    typealias Permission = MediaPermission

    private(set) var permission = Permission.unknown
    private(set) var level: Float = -120
    private(set) var peak: Float = -120
    private(set) var recording = false
    private(set) var playingBack = false
    private(set) var hasRecording = false

    @ObservationIgnored private let meter = MicrophoneLevel()

    init() {
        meter.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    var detail: String { meter.detail }

    func start() async { meter.start() }
    func record(seconds: Double) { meter.record(seconds: seconds) }
    func playBack() { meter.playBack() }
    func stop() {
        meter.stop()
        sync()
    }

    private func sync() {
        if meter.permission != permission { permission = meter.permission }
        level = meter.level
        if meter.peak != peak { peak = meter.peak }
        if meter.recording != recording { recording = meter.recording }
        if meter.playingBack != playingBack { playingBack = meter.playingBack }
        if meter.hasRecording != hasRecording { hasRecording = meter.hasRecording }
    }
}
