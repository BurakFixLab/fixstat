import Foundation
import MacSensors

// sensormap — finds out which temperature sensor is which by applying
// targeted loads (CPU, GPU, SSD, charging) and measuring each sensor's rise.
// Read-only: no SMC writes, no root privileges.

let usage = """
    usage:
      sensormap record [--tests single,all,gpu,ssd,charger] [--duration S] [--baseline S] [--out FILE]
      sensormap report FILE...
      sensormap propose FILE... [--write PATH]

    record   Idle baseline, then each test (default 45 s) with cooldown in between.
             The charger test asks you to unplug and re-plug the power adapter.
             Default output: local/sensormap/<model>-<timestamp>.json (git-ignored).
    report   Prints the per-sensor temperature change for each test.
    propose  Proposes sensor-map entries for this model from recordings.
    """

func fail(_ message: String) -> Never {
    log("sensormap: \(message)\n\n\(usage)")
    exit(2)
}

func loadRecordings(_ paths: [String]) -> [Recording] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return paths.map { path in
        guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
        do {
            return try decoder.decode(Recording.self, from: data)
        } catch {
            fail("cannot parse \(path): \(error)")
        }
    }
}

func alert(_ message: String) {
    log("\n>>> \(message)\n")
    let sound = Process()
    sound.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    sound.arguments = ["/System/Library/Sounds/Glass.aiff"]
    try? sound.run()
}

func waitForPower(connected: Bool, recorder: Recorder, timeout: TimeInterval = 1800) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        recorder.takeSample()
        if BatteryReader.read()?.externalConnected == connected { return true }
        Thread.sleep(forTimeInterval: 1)
    }
    return false
}

func record(_ arguments: [String]) {
    var tests = ["single", "all", "gpu", "ssd"]
    var duration: TimeInterval = 45
    var baseline: TimeInterval = 30
    var outPath: String?

    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--tests": tests = (iterator.next() ?? "").split(separator: ",").map(String.init)
        case "--duration": duration = TimeInterval(iterator.next() ?? "") ?? duration
        case "--baseline": baseline = TimeInterval(iterator.next() ?? "") ?? baseline
        case "--out": outPath = iterator.next()
        default: fail("unknown option \(argument)")
        }
    }
    let known = Set(["single", "all", "gpu", "ssd", "charger"])
    if let unknown = tests.first(where: { !known.contains($0) }) { fail("unknown test \(unknown)") }

    let recorder = Recorder()
    let system = recorder.recording.system
    log("sensormap: \(system.model) · \(system.chip) · \(recorder.sampler.sensors.count) temperature sensors")
    log("Keep the Mac idle (no other work) until the recording ends.\n")

    log("baseline (\(Int(baseline)) s)")
    recorder.phase("baseline", duration: baseline)

    for test in tests {
        let reference = recorder.recentMeanHID()
        switch test {
        case "single", "all", "gpu", "ssd":
            let flag = StopFlag()
            switch test {
            case "single":
                LoadGenerator.cpu(threads: 1, flag: flag)
            case "all":
                LoadGenerator.cpu(threads: ProcessInfo.processInfo.activeProcessorCount, flag: flag)
            case "gpu":
                if let error = LoadGenerator.gpu(flag: flag) {
                    log("gpu test skipped: \(error)")
                    continue
                }
            default:
                LoadGenerator.ssd(directory: FileManager.default.temporaryDirectory, fileSize: 2 << 30, flag: flag)
            }
            log("\(test) load (\(Int(duration)) s)")
            recorder.phase(test, duration: duration)
            flag.stop()
            log("cooldown")
            recorder.cooldown(to: reference, minimum: 20, maximum: 120)

        case "charger":
            if BatteryReader.read()?.externalConnected == true {
                alert("UNPLUG the power adapter now.")
                guard waitForPower(connected: false, recorder: recorder) else {
                    log("charger test skipped: adapter was not unplugged within 30 min")
                    continue
                }
            }
            log("on battery (90 s)")
            recorder.phase("unplugged", duration: 90)
            alert("PLUG IN the power adapter now.")
            guard waitForPower(connected: true, recorder: recorder) else {
                log("charger test incomplete: adapter was not plugged in within 30 min")
                continue
            }
            log("charging (180 s)")
            recorder.phase("charging", duration: 180)

        default:
            break
        }
    }

    let url: URL
    if let outPath {
        url = URL(fileURLWithPath: outPath)
    } else {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: "local/sensormap", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("\(system.model)-\(stamp).json")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    do {
        try encoder.encode(recorder.recording).write(to: url)
    } catch {
        fail("cannot write \(url.path): \(error)")
    }
    log("\nsaved \(url.path)\n")
    let rows = Report.deltas(for: [recorder.recording])
    print(Report.render(rows, tests: Report.testOrder.filter { name in rows.contains { $0.deltas[name] != nil } }))
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("missing command") }
arguments.removeFirst()

switch command {
case "record":
    record(arguments)
case "report":
    guard !arguments.isEmpty else { fail("report needs at least one recording") }
    let rows = Report.deltas(for: loadRecordings(arguments))
    print(Report.render(rows, tests: Report.testOrder.filter { name in rows.contains { $0.deltas[name] != nil } }))
case "propose":
    var files: [String] = []
    var writePath: String?
    var mapPath = "SensorMaps/sensor-map.json"
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--write": writePath = iterator.next()
        case "--map": mapPath = iterator.next() ?? mapPath
        default: files.append(argument)
        }
    }
    guard !files.isEmpty else { fail("propose needs at least one recording") }
    let recordings = loadRecordings(files)
    var map: SensorMap
    do {
        map = try SensorMap.load(from: URL(fileURLWithPath: mapPath))
    } catch {
        fail("cannot load \(mapPath): \(error)")
    }
    let proposal = Proposer.propose(recordings: recordings, map: map)
    let model = recordings[0].system.model
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let writePath {
        if map.models[model] != nil {
            log("note: replacing the existing entry for \(model)")
        }
        map.models[model] = proposal.model
        do {
            try (encoder.encode(map) + Data("\n".utf8)).write(to: URL(fileURLWithPath: writePath))
        } catch {
            fail("cannot write \(writePath): \(error)")
        }
        log("wrote \(writePath)")
    } else {
        print(String(decoding: try encoder.encode([model: proposal.model]), as: UTF8.self))
    }
    let verified = proposal.model.sensors.filter { $0.confidence == .verified }.count
    log("\(proposal.model.sensors.count) mapped (\(verified) verified by test), "
        + "\(proposal.model.ignored?.count ?? 0) ignored, \(proposal.model.derived?.count ?? 0) derived, "
        + "\(proposal.unmatched.count) unmatched")
    for sensor in proposal.unmatched {
        log("  unmatched: \(sensor.rawLabel)" + (sensor.hidName.map { " (\($0))" } ?? ""))
    }
case "-h", "--help":
    print(usage)
default:
    fail("unknown command \(command)")
}
