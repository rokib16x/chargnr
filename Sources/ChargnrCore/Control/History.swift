import Foundation

/// One point in the battery history.
public struct HistorySample: Codable, Equatable, Sendable {
    public var time: Date
    public var percent: Int
    public var pluggedIn: Bool
    public var charging: Bool
    public var temperatureC: Double?
    /// Battery power in milliwatts: positive charging, negative discharging.
    public var batteryMW: Int?
    /// chargnr had charging or the adapter switched off.
    public var held: Bool

    public init(time: Date, percent: Int, pluggedIn: Bool, charging: Bool,
                temperatureC: Double? = nil, batteryMW: Int? = nil, held: Bool = false) {
        self.time = time
        self.percent = percent
        self.pluggedIn = pluggedIn
        self.charging = charging
        self.temperatureC = temperatureC
        self.batteryMW = batteryMW
        self.held = held
    }

    /// Compact CSV: `epoch,percent,plugged,charging,held,tempTenths,batteryMW`.
    var line: String {
        [String(Int(time.timeIntervalSince1970)), String(percent), pluggedIn ? "1" : "0", charging ? "1" : "0",
         held ? "1" : "0", temperatureC.map { String(Int(($0 * 10).rounded())) } ?? "", batteryMW.map(String.init) ?? ""]
            .joined(separator: ",")
    }

    init?(line: Substring) {
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count >= 7, let epoch = Double(f[0]), let percent = Int(f[1]) else { return nil }
        self.init(time: Date(timeIntervalSince1970: epoch), percent: percent, pluggedIn: f[2] == "1",
                  charging: f[3] == "1", temperatureC: Int(f[5]).map { Double($0) / 10 },
                  batteryMW: Int(f[6]), held: f[4] == "1")
    }

    /// Whether `self` differs from `other` enough to be worth a new sample.
    func differs(from other: HistorySample) -> Bool {
        percent != other.percent || pluggedIn != other.pluggedIn || charging != other.charging || held != other.held
    }
}

public enum HistoryCSV {
    public static func encode(_ samples: [HistorySample]) -> Data {
        Data(samples.map(\.line).joined(separator: "\n").utf8)
    }

    public static func decode(_ data: Data) -> [HistorySample] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap(HistorySample.init(line:))
    }
}

/// The helper's battery log. Appends only on change (or every 10 minutes), so
/// a month is a few hundred KB, and trims itself to `retention`.
public final class HistoryStore: @unchecked Sendable {
    public let url: URL
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    /// Record at least this often even when nothing changes, for a smooth chart.
    public static let heartbeat: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var last: HistorySample?
    private var lastTrim: Date?

    public init(url: URL = HelperPaths.directory.appendingPathComponent("history.csv")) {
        self.url = url
        last = Self.readAll(url).last
    }

    /// Adds `sample` if it differs from the last one or the heartbeat is due.
    public func record(_ sample: HistorySample) {
        lock.lock()
        defer { lock.unlock() }
        if let last, !sample.differs(from: last), sample.time.timeIntervalSince(last.time) < Self.heartbeat { return }
        append(sample.line + "\n")
        last = sample
        if lastTrim.map({ sample.time.timeIntervalSince($0) > 24 * 60 * 60 }) ?? true {
            trim(before: sample.time.addingTimeInterval(-Self.retention))
            lastTrim = sample.time
        }
    }

    public func samples(since: Date) -> [HistorySample] {
        lock.lock()
        defer { lock.unlock() }
        return Self.readAll(url).filter { $0.time >= since }
    }

    private func append(_ text: String) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func trim(before cutoff: Date) {
        let all = Self.readAll(url)
        guard let first = all.first, first.time < cutoff else { return }
        let kept = all.filter { $0.time >= cutoff }
        try? (HistoryCSV.encode(kept) + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    private static func readAll(_ url: URL) -> [HistorySample] {
        (try? Data(contentsOf: url)).map(HistoryCSV.decode) ?? []
    }
}

/// Summary numbers for a stretch of history.
public struct HistorySummary: Sendable, Equatable {
    public var minPercent: Int
    public var maxPercent: Int
    /// Share of time plugged in, 0–1.
    public var pluggedShare: Double
    /// Share of time at 95% or more, which ages a battery fastest.
    public var nearFullShare: Double
    /// Share of time chargnr held charging back.
    public var heldShare: Double
    public var maxTemperatureC: Double?

    /// Time-weighted: each sample counts until the next one.
    public init?(_ samples: [HistorySample], until end: Date = Date()) {
        guard !samples.isEmpty else { return nil }
        var plugged = 0.0, nearFull = 0.0, held = 0.0, total = 0.0
        for (index, sample) in samples.enumerated() {
            let next = index + 1 < samples.count ? samples[index + 1].time : end
            let span = max(0, next.timeIntervalSince(sample.time))
            total += span
            if sample.pluggedIn { plugged += span }
            if sample.percent >= 95 { nearFull += span }
            if sample.held { held += span }
        }
        let divisor = max(total, 1)
        minPercent = samples.map(\.percent).min() ?? 0
        maxPercent = samples.map(\.percent).max() ?? 0
        pluggedShare = plugged / divisor
        nearFullShare = nearFull / divisor
        heldShare = held / divisor
        maxTemperatureC = samples.compactMap(\.temperatureC).max()
    }
}
