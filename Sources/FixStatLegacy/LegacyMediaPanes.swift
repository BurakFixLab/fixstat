import AVFoundation
import AppKit
import MacSensors
import FixStatCore

// MARK: - Speakers

final class LegacySpeakerPane: BlockPane {
    private let player = TonePlayer()
    private var device = AudioDevice.defaultDevice(input: false)
    private var played: Set<TonePlayer.Tone> = []

    override init(core: MonitorCore) {
        super.init(core: core)
        player.onChange = { [weak self] in self?.refresh() }
    }

    override func deactivate() {
        player.stop()
    }

    override func blocks() -> [Block] {
        var blocks: [Block] = []
        if let device {
            blocks.append(.headline(device.name, nil))
            if device.muted == true {
                blocks.append(.status(L("Output is muted."), .bad))
            } else if let volume = device.volume {
                blocks.append(volume < 0.25 ? .status(L("Volume %@", Format.percent(Double(volume) * 100)), .bad)
                                            : .secondary(L("Volume %@", Format.percent(Double(volume) * 100))))
            }
            if !device.isBuiltIn {
                blocks.append(.status(L("This is not the built-in output. Unplug headphones or choose the internal speakers."), .bad))
            }
        }
        var buttons: [NSView] = [(L("Left"), TonePlayer.Tone.left), (L("Right"), .right), (L("Both"), .both), (L("Sweep"), .sweep)]
            .map { title, tone in
                let button = ActionButton(title: (player.playing == tone ? "♪ " : "") + title) { [unowned self] in play(tone) }
                if #available(macOS 11.0, *) { button.controlSize = .large }
                return button
            }
        if player.playing != nil {
            buttons.append(ActionButton(title: L("Stop")) { [unowned self] in player.stop() })
        }
        blocks.append(.view(hStack(buttons + [makeSpacer()], spacing: 10)))
        return blocks
    }

    private func play(_ tone: TonePlayer.Tone) {
        device = AudioDevice.defaultDevice(input: false)
        player.play(tone)
        played.insert(tone)
        let names = TonePlayer.Tone.allCases.filter(played.contains).map(TonePlayer.name)
        core.recordCheck(.speakers, detail: ([device?.name].compactMap { $0 } + names).joined(separator: " · "))
    }
}

// MARK: - Microphone

final class LegacyMicrophonePane: BlockPane {
    private let meter = MicrophoneLevel()
    private let bar = LevelBar(height: 12)
    private let levelLabel = makeLabel("", color: .secondaryLabelColor)
    private var lastPeak: Float = -120
    private var evidencePending = false
    private var structure = ""

    override init(core: MonitorCore) {
        super.init(core: core)
        bar.color = LegacyStyle.cool
        meter.onChange = { [weak self] in
            guard let self else { return }
            // The level changes many times a second: update it in place.
            updateLevel()
            if meter.peak > -120, meter.peak != lastPeak {
                lastPeak = meter.peak
                recordEvidence()
            }
            let key = "\(meter.permission)\(meter.recording)\(meter.playingBack)\(meter.hasRecording)"
            if key != structure {
                structure = key
                refresh()
            }
        }
    }

    private func updateLevel() {
        bar.fraction = (Double(meter.level) + 60) / 60
        levelLabel.stringValue = L("Level %@ · peak %@", Format.decibels(Double(meter.level), unit: "dBFS"),
                                   Format.decibels(Double(meter.peak), unit: "dBFS"))
    }

    /// At most twice a second through the checklist.
    private func recordEvidence() {
        guard !evidencePending else { return }
        evidencePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            evidencePending = false
            core.recordCheck(.microphone, detail: meter.detail)
        }
    }

    override func activate() {
        super.activate()
        meter.start()
    }

    override func deactivate() {
        meter.stop()
    }

    override func blocks() -> [Block] {
        var blocks: [Block] = []
        if let device = AudioDevice.defaultDevice(input: true) {
            blocks.append(.headline(device.name, nil))
        }
        if meter.permission == .denied {
            blocks.append(.status(L("FixStat has no microphone access. Allow it in System Settings › Privacy & Security › Microphone."), .bad))
            blocks.append(.actions([DocAction(title: L("Open System Settings")) { MediaPermission.openSettings("Privacy_Microphone") }]))
            return blocks
        }
        updateLevel()
        blocks.append(.view(bar))
        blocks.append(.view(levelLabel))
        let record = ActionButton(title: meter.recording ? L("Recording…") : L("Record 4 s")) { [unowned self] in
            meter.record(seconds: 4)
        }
        record.isEnabled = !meter.recording && !meter.playingBack
        let play = ActionButton(title: L("Play back")) { [unowned self] in meter.playBack() }
        play.isEnabled = meter.hasRecording && !meter.recording && !meter.playingBack
        blocks.append(.view(hStack([record, play, makeSpacer()])))
        return blocks
    }
}

// MARK: - Camera

final class LegacyCameraPane: BlockPane {
    private let camera = CameraCapture()
    private let preview = CameraPreviewView()
    private var lastSecond = -1
    private var started = false

    override init(core: MonitorCore) {
        super.init(core: core)
        preview.session = camera.session
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 9.0 / 16.0).isActive = true
        camera.onChange = { [weak self] in
            guard let self else { return }
            let second = camera.frames / 30
            if second != lastSecond {
                lastSecond = second
                if let detail = camera.detail { core.recordCheck(.camera, detail: detail) }
                refresh()
            }
        }
    }

    override func activate() {
        super.activate()
        camera.start()
    }

    override func deactivate() {
        camera.stop()
    }

    override func blocks() -> [Block] {
        switch camera.permission {
        case .denied:
            return [.status(L("FixStat has no camera access. Allow it in System Settings › Privacy & Security › Camera."), .bad),
                    .actions([DocAction(title: L("Open System Settings")) { MediaPermission.openSettings("Privacy_Camera") }])]
        case .noCamera:
            return [.status(L("No camera found."), .bad)]
        default:
            var blocks: [Block] = []
            if let name = camera.deviceName {
                blocks.append(.headline([name, camera.resolution].compactMap { $0 }.joined(separator: " · "), nil))
            }
            blocks.append(.view(preview))
            if let brightness = camera.brightness {
                blocks.append(.secondary(L("%@ frames · average brightness %@", Format.number(Double(camera.frames)),
                                           Format.percent(brightness * 100))))
                if camera.looksBlack {
                    blocks.append(.status(L("The image is black. Check that nothing covers the camera; otherwise suspect the camera or its cable."), .bad))
                }
            }
            return blocks
        }
    }
}

/// Live camera image (AVCaptureVideoPreviewLayer).
final class CameraPreviewView: NSView {
    var session: AVCaptureSession? {
        didSet {
            let layer = AVCaptureVideoPreviewLayer()
            layer.session = session
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = NSColor.black.cgColor
            layer.cornerRadius = 8
            self.layer = layer
            wantsLayer = true
        }
    }
}

// MARK: - Ambient light

final class LegacyAmbientLightPane: BlockPane {
    private let runner = LightTestRunner()
    private var lastResult = 0
    private var reportedMissing = false
    private var structure = ""
    private let readingLabel = makeLabel("–", size: 28, weight: .semibold)

    override init(core: MonitorCore) {
        super.init(core: core)
        runner.onChange = { [weak self] in
            guard let self else { return }
            readingLabel.stringValue = runner.reading.map { LightText.value($0) } ?? "–"
            if runner.available == false, !reportedMissing {
                reportedMissing = true
                core.recordCheck(.ambientLight, detail: LightText.finding(.notFound), failed: true)
            }
            if runner.resultID != lastResult, let result = runner.result {
                lastResult = runner.resultID
                core.recordCheck(.ambientLight, detail: runner.detail ?? "", passed: result.verdict == .passed,
                                 failed: result.verdict == .failed)
            }
            // Rebuild only when the steps, prompt or result change (the reading ticks 4 × a second).
            let key = [String(describing: runner.available), "\(runner.phase)", runner.prompt ?? "", "\(runner.resultID)",
                       "\(runner.cameraPermissionDenied)", runner.roomMean.map { LightText.value($0) } ?? "",
                       runner.coveredMin.map { LightText.value($0) } ?? "", runner.brightMax.map { LightText.value($0) } ?? ""]
                .joined(separator: "|")
            if key != structure {
                structure = key
                refresh()
            }
        }
    }

    override func activate() {
        runner.prepare()
        super.activate()
    }

    override func deactivate() {
        runner.stop()
    }

    override func blocks() -> [Block] {
        if runner.available == false {
            return [.status(L("No ambient light sensor found. On MacBooks this points to the camera board or the display cable."), .bad)]
        }
        var blocks: [Block] = []
        readingLabel.stringValue = runner.reading.map { LightText.value($0) } ?? "–"
        var top: [NSView] = [readingLabel]
        if let auto = AmbientLightSensor.automaticBrightnessEnabled {
            top.append(makeLabel(auto ? L("Automatic brightness: on") : L("Automatic brightness: off"), color: .secondaryLabelColor))
        }
        blocks.append(.view(hStack(top + [makeSpacer()], spacing: 16, alignment: .firstBaseline)))
        let phase = runner.phase
        let steps: [(String, Bool, Bool, LightReadingValue?)] = [
            (L("Normal light"), phase.rawValue > LightTestRunner.Phase.room.rawValue, phase == .room, runner.roomMean),
            (L("Cover the sensor"), phase.rawValue > LightTestRunner.Phase.covered.rawValue, phase == .covered, runner.coveredMin),
            (L("Flashlight"), phase == .done, phase == .bright || phase == .confirm, runner.brightMax),
        ]
        blocks.append(.rows(steps.enumerated().map { index, step in
            DocRow(title: (step.1 ? "✓ " : step.2 ? "▸ " : "○ ") + L("%lld. ", index + 1) + step.0,
                   value: step.3.map { LightText.value($0) } ?? "")
        }, labelWidth: 260))
        if let prompt = runner.prompt {
            blocks.append(.headline("☞ " + prompt, nil))
        }
        if phase == .confirm {
            blocks.append(.actions([
                DocAction(title: L("Yes, the light was on the sensor")) { [unowned self] in runner.confirmLight(true) },
                DocAction(title: L("Try again")) { [unowned self] in runner.confirmLight(false) },
            ]))
        }
        var start: [NSView] = [ActionButton(title: phase == .idle ? L("Start test") : L("Restart")) { [unowned self] in runner.start() }]
        if runner.cameraPermissionDenied {
            start.append(makeLabel(L("Without camera access the flashlight is confirmed by hand."), size: LegacyStyle.caption,
                                   color: .secondaryLabelColor))
        }
        blocks.append(.view(hStack(start + [makeSpacer()])))
        if let result = runner.result {
            if result.verdict == .passed {
                blocks.append(.headline(L("The ambient light sensor responds correctly."), .good))
            }
            blocks.append(.list(result.findings.map { .status(LightText.finding($0), $0 == .cameraDidNotSeeLight ? .neutral : .bad) }))
        }
        return blocks
    }
}
