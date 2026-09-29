import Foundation
import MacSensors

// sensormap — finds out which temperature sensor is which by applying
// targeted loads (CPU, GPU, SSD, charging) and measuring each sensor's rise.
// Read-only: no SMC writes, no root privileges.

let usage = """
    usage:
      sensormap record [--quick] [--tests single,all,gpu,ssd,charger] [--duration S] [--baseline S] [--out FILE]
      sensormap report FILE...
      sensormap propose FILE... [--write PATH]
      sensormap ssd [--gb N]

    record   Idle baseline, then each test (default 45 s) with cooldown in between.
             --quick: all cores, GPU and SSD for 30 s each (about 3 minutes).
             The charger test asks you to unplug and re-plug the power adapter.
             Default output: local/sensormap/<model>-<timestamp>.json (git-ignored).
    report   Prints the per-sensor temperature change for each test.
    propose  Proposes sensor-map entries for this model from recordings.
    ssd      Write–verify stress test of the internal SSD on free space (default 4 GB).
             Uses write endurance; at least 10 GB are always left free.
    """

func fail(_ message: String) -> Never {
    log("sensormap: \(message)\n\n\(usage)")
    exit(2)
}

func loadRecordings(_ paths: [String]) -> [SensorRecording] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return paths.map { path in
        guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
        do {
            return try decoder.decode(SensorRecording.self, from: data)
        } catch {
            fail("cannot parse \(path): \(error)")
        }
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func alert(_ message: String) {
    log("\n>>> \(message)\n")
    let sound = Process()
    sound.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    sound.arguments = ["/System/Library/Sounds/Glass.aiff"]
    try? sound.run()
}

func waitForPower(connected: Bool, recorder: SensorRecorder, timeout: TimeInterval = 1800) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        recorder.takeSample()
        if BatteryReader.read()?.externalConnected == connected { return true }
        Thread.sleep(forTimeInterval: 1)
    }
    return false
}

func record(_ arguments: [String]) {
    var plan = SensorLoadTests.Plan.full
    var charger = false
    var outPath: String?

    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--quick": plan = .quick
        case "--tests":
            let tests = (iterator.next() ?? "").split(separator: ",").map(String.init)
            charger = tests.contains("charger")
            plan.tests = tests.filter { $0 != "charger" }
        case "--duration": plan.duration = TimeInterval(iterator.next() ?? "") ?? plan.duration
        case "--baseline": plan.baseline = TimeInterval(iterator.next() ?? "") ?? plan.baseline
        case "--out": outPath = iterator.next()
        default: fail("unknown option \(argument)")
        }
    }
    if let unknown = plan.tests.first(where: { !SensorLoadTests.loadTests.contains($0) }) { fail("unknown test \(unknown)") }

    let recorder = SensorRecorder()
    recorder.progress = log
    let system = recorder.recording.system
    log("sensormap: \(system.model) · \(system.chip) · \(recorder.sampler.sensors.count) temperature sensors")
    log("Keep the Mac idle (no other work) until the recording ends.\n")

    SensorLoadTests.run(plan, recorder: recorder)

    if charger {
        if BatteryReader.read()?.externalConnected == true {
            alert("UNPLUG the power adapter now.")
            if !waitForPower(connected: false, recorder: recorder) {
                log("charger test skipped: adapter was not unplugged within 30 min")
            }
        }
        if BatteryReader.read()?.externalConnected == false {
            log("on battery (90 s)")
            recorder.phase("unplugged", duration: 90)
            alert("PLUG IN the power adapter now.")
            if waitForPower(connected: true, recorder: recorder) {
                log("charging (180 s)")
                recorder.phase("charging", duration: 180)
            } else {
                log("charger test incomplete: adapter was not plugged in within 30 min")
            }
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
    let rows = SensorMapReport.deltas(for: [recorder.recording])
    print(SensorMapReport.render(rows, tests: SensorMapReport.testOrder.filter { name in rows.contains { $0.deltas[name] != nil } }))
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("missing command") }
arguments.removeFirst()

switch command {
case "record":
    record(arguments)
case "report":
    guard !arguments.isEmpty else { fail("report needs at least one recording") }
    let rows = SensorMapReport.deltas(for: loadRecordings(arguments))
    print(SensorMapReport.render(rows, tests: SensorMapReport.testOrder.filter { name in rows.contains { $0.deltas[name] != nil } }))
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
    let proposal = SensorMapProposer.propose(recordings: recordings, map: map)
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
case "ssd":
    var gigabytes = 4.0
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        if argument == "--gb", let value = iterator.next().flatMap(Double.init) { gigabytes = value }
        else { fail("unknown option \(argument)") }
    }
    let test = SSDStressTest()
    let directory = FileManager.default.temporaryDirectory
    log("SSD write–verify test: \(gigabytes) GB in \(directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
    let result = test.run(bytes: Int64(gigabytes * 1_073_741_824), directory: directory) { p in
        if p.chunk % 64 == 0 || p.chunk == p.chunkCount {
            log("  \(p.phase.rawValue) \(p.chunk)/\(p.chunkCount)  \(Int(p.throughput)) MB/s")
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    var summary = result
    summary.timings = []
    print(String(decoding: try encoder.encode(summary), as: UTF8.self))
    let writes = result.timings.map(\.write).sorted()
    let reads = result.timings.compactMap(\.read).sorted()
    if !writes.isEmpty, !reads.isEmpty {
        log(String(format: "chunk ms  write median %.1f max %.1f · read median %.1f max %.1f",
                   writes[writes.count / 2] * 1000, writes.last! * 1000, reads[reads.count / 2] * 1000, reads.last! * 1000))
    }
case "-h", "--help":
    print(usage)
default:
    fail("unknown command \(command)")
}
