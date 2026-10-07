import Foundation
import MacSensors

/// Looks up the latest FixStat release on GitHub (the public releases API, no account, nothing
/// about the Mac is sent) once a day and remembers what it found. FixStat does not install
/// updates itself: it tells the technician and opens the download page.
public final class UpdateChecker {
    public static let shared = UpdateChecker()

    public struct Release: Equatable {
        public var version: String
        public var url: URL
    }

    public enum Status: Equatable {
        case unknown, checking, upToDate, failed
        case available(Release)
    }

    public private(set) var status = Status.unknown
    /// When the last check succeeded.
    public private(set) var lastCheck: Date?
    /// Called on the main thread when `status` changed (one listener: the running interface).
    public var onChange: (() -> Void)?

    public static let latestURL = URL(string: "https://api.github.com/repos/BurakFixLab/fixstat/releases/latest")!
    public static let releasesURL = URL(string: "https://github.com/BurakFixLab/fixstat/releases")!
    public static let interval: TimeInterval = 24 * 3600

    private enum Key {
        static let lastCheck = "update.lastCheck"
        static let version = "update.latestVersion"
        static let url = "update.latestURL"
        static let notified = "update.notifiedVersion"
    }

    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private init() {
        lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
        if let version = defaults.string(forKey: Key.version), Self.isNewer(version, than: AboutInfo.version) {
            let url = defaults.string(forKey: Key.url).flatMap(URL.init(string:)) ?? Self.releasesURL
            status = .available(Release(version: version, url: url))
        } else if lastCheck != nil {
            status = .upToDate
        }
        // `-FixStatSampleUpdate 9.9` pretends a newer release exists (no network).
        if let sample = defaults.string(forKey: "FixStatSampleUpdate") {
            status = .available(Release(version: sample, url: Self.releasesURL))
        }
    }

    public var available: Release? {
        if case let .available(release) = status { return release }
        return nil
    }

    /// Checks shortly after launch and then once a day, while `Pref.checkForUpdates` is on.
    /// Never during snapshots or exports.
    public func start() {
        let arguments = CommandLine.arguments
        guard timer == nil, !arguments.contains("--snapshot"), !arguments.contains("--export"),
              defaults.string(forKey: "FixStatSampleUpdate") == nil else { return }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard defaults.bool(forKey: Pref.checkForUpdates) else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < Self.interval { return }
        check()
    }

    /// Asks GitHub now ("Check now", or when due).
    public func check() {
        guard status != .checking else { return }
        let previous = status
        status = .checking
        onChange?()
        var request = URLRequest(url: Self.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FixStat/\(AboutInfo.version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let release = ok ? data.flatMap(Self.parse) : nil
            DispatchQueue.main.async { [weak self] in
                self?.finish(release, failed: !ok || release == nil, previous: previous)
            }
        }.resume()
    }

    private func finish(_ release: Release?, failed: Bool, previous: Status) {
        guard !failed, let release else {
            // Keep a known update visible when offline.
            if case .available = previous { status = previous } else { status = .failed }
            onChange?()
            return
        }
        lastCheck = Date()
        defaults.set(lastCheck, forKey: Key.lastCheck)
        defaults.set(release.version, forKey: Key.version)
        defaults.set(release.url.absoluteString, forKey: Key.url)
        if Self.isNewer(release.version, than: AboutInfo.version) {
            status = .available(release)
            // One notification per new version.
            if defaults.string(forKey: Key.notified) != release.version {
                defaults.set(release.version, forKey: Key.notified)
                AlertManager.sender?(.updateAvailable,
                                     L("FixStat %@ is available. Open the menu bar panel to download it.", release.version))
            }
        } else {
            status = .upToDate
        }
        onChange?()
    }

    /// The latest stable release from the API's JSON (drafts and prereleases are skipped).
    static func parse(_ data: Data) -> Release? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let url = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesURL
        return Release(version: version, url: url)
    }

    /// "1.10" is newer than "1.9.2"; missing components count as 0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

public enum UpdateText {
    public static func status(_ status: UpdateChecker.Status, lastCheck: Date?) -> String {
        switch status {
        case .unknown: return L("Not checked yet")
        case .checking: return L("Checking…")
        case .failed: return L("Could not reach GitHub")
        case .upToDate:
            return lastCheck.map { L("Up to date · checked %@", Format.dateTime($0)) } ?? L("Up to date")
        case let .available(release): return L("FixStat %@ is available", release.version)
        }
    }

    public static let privacy = L("Asks GitHub once a day which FixStat release is the latest. Nothing about this Mac is sent.")
}
