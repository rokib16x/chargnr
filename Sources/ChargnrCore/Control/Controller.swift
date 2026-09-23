import Foundation
import os

/// A battery reading the controller acts on.
public struct BatteryReading: Equatable, Sendable {
    public var percent: Int
    public var pluggedIn: Bool
    public var temperatureC: Double?

    public init(percent: Int, pluggedIn: Bool, temperatureC: Double? = nil) {
        self.percent = percent
        self.pluggedIn = pluggedIn
        self.temperatureC = temperatureC
    }

    /// Reads the SMC, which answers even when IOKit's battery service lags.
    public static func read(_ smc: some SMCTransport) -> BatteryReading? {
        let state = ChargeState.read(smc, Capabilities(charging: .unsupported, canInhibit: false, adapterKey: nil,
                                                       magSafeLED: false, temperature: smc.exists(SMCKeys.batteryTemperature)))
        guard let percent = state.percent, let plugged = state.pluggedIn else { return nil }
        return BatteryReading(percent: percent, pluggedIn: plugged, temperatureC: state.temperatureC)
    }
}

/// What the helper reports to the app and CLI.
public struct HelperStatus: Codable, Equatable, Sendable {
    public var version: String
    public var config: ChargeConfig
    public var method: ControlMethod
    public var output: ChargeOutput
    public var percent: Int?
    public var pluggedIn: Bool?
    public var temperatureC: Double?
    /// Heat protection is pausing charging right now.
    public var heatHold: Bool?
    public var lastError: String?
    /// Seconds until the next scheduled check.
    public var nextCheck: Int
}

/// The helper's brain: loads the config, runs the policy, drives the
/// actuator, and puts everything back to normal on crash, sleep and exit.
/// All calls must come from one serial queue.
public final class Controller: @unchecked Sendable {
    private let actuator: Actuator
    private let configFile: JSONFile<ChargeConfig>
    private let marker: JSONFile<ChargeOutput>
    private let readBattery: @Sendable () -> BatteryReading?
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: Chargnr.helperID, category: "controller")

    public private(set) var config: ChargeConfig
    private var output = ChargeOutput.normal
    private var reading: BatteryReading?
    private var lastError: String?
    /// When heat protection started holding, or nil when it is not.
    private var hotSince: Date?

    public init(actuator: Actuator,
                configFile: JSONFile<ChargeConfig> = JSONFile(HelperPaths.config),
                marker: JSONFile<ChargeOutput> = JSONFile(HelperPaths.dirtyMarker),
                now: @escaping @Sendable () -> Date = Date.init,
                readBattery: @escaping @Sendable () -> BatteryReading?) {
        self.actuator = actuator
        self.configFile = configFile
        self.marker = marker
        self.now = now
        self.readBattery = readBattery
        config = configFile.load()?.normalized ?? ChargeConfig()
    }

    public var method: ControlMethod {
        ControlMethod.choose(for: config, caps: actuator.caps)
    }

    /// Call once at launch. If the last run left switches changed (crash,
    /// kill -9, power loss), put them back before doing anything else.
    public func start() {
        if let left = marker.load() {
            log.notice("previous run left switches at \(String(describing: left)); restoring")
        }
        // Restore unconditionally: another tool may have changed keys too, and
        // the policy re-applies whatever is needed on the first tick.
        restore()
        tick()
    }

    /// Re-reads the battery and applies the policy.
    @discardableResult
    public func tick() -> TimeInterval {
        reading = readBattery()
        if let reading {
            updateHeat(reading.temperatureC)
            let next = ChargePolicy.decide(PolicyInput(
                config: config, method: method, percent: reading.percent, pluggedIn: reading.pluggedIn,
                hot: hotSince != nil, canInhibit: actuator.caps.canInhibit,
                canCutAdapter: actuator.caps.canDisableAdapter, previous: output))
            apply(next)
        }
        return interval
    }

    /// Starts holding at the heat limit; stops only once the battery has
    /// cooled a little and the cooldown has passed, so it does not flap.
    private func updateHeat(_ temperature: Double?) {
        guard let limit = config.heatLimit.map(Double.init), let temperature else {
            hotSince = nil
            return
        }
        if let since = hotSince {
            let cooled = temperature <= limit - ChargeConfig.heatHysteresis
            if cooled && now().timeIntervalSince(since) >= ChargeConfig.heatCooldown {
                hotSince = nil
                log.notice("battery cooled to \(temperature, format: .fixed(precision: 1)) °C; heat protection off")
            }
        } else if temperature >= limit {
            hotSince = now()
            log.notice("battery at \(temperature, format: .fixed(precision: 1)) °C; pausing charging")
        }
    }

    public func setConfig(_ new: ChargeConfig) throws {
        let new = new.normalized
        try configFile.save(new)
        config = new
        log.notice("config: limit \(new.limit)% gap \(new.gap) heat \(new.heatLimit.map { "\($0) °C" } ?? "off"), method \(self.method.rawValue)")
        tick()
    }

    /// Before sleep nothing can switch the adapter back on, so a cut adapter
    /// (for the limit or for heat) would drain the battery. Restore it;
    /// macOS's own limit (80% floor for sub-80 limits) keeps sleep charging in
    /// check. With charge keys, stop charging so the Mac cannot creep past the limit.
    public func willSleep() {
        var next = output
        next.adapterOn = true
        if method == .inhibit { next.chargingAllowed = false }
        apply(next)
    }

    public func didWake() {
        tick()
    }

    /// Everything back to normal. Used on exit, uninstall and on request.
    public func restore() {
        do {
            try actuator.restoreNormal()
            output = .normal
            marker.remove()
            lastError = nil
        } catch {
            lastError = "restore failed: \(error)"
            log.error("restore failed: \(String(describing: error))")
        }
    }

    public func status() -> HelperStatus {
        HelperStatus(version: Chargnr.version, config: config, method: method, output: output,
                     percent: reading?.percent, pluggedIn: reading?.pluggedIn,
                     temperatureC: reading?.temperatureC, heatHold: config.heatLimit == nil ? nil : hotSince != nil,
                     lastError: lastError,
                     nextCheck: Int(interval))
    }

    /// How long until the next check. Far from the limit the battery takes
    /// minutes to move a point, so checking often would only waste wakeups.
    /// Power-source events trigger extra checks in between.
    public var interval: TimeInterval {
        guard let reading else { return 300 }
        if output != .normal { return 20 }
        // Temperature can climb within minutes while charging.
        if config.heatLimit != nil, reading.pluggedIn { return 60 }
        guard method != .none else { return 300 }
        let distance = config.limit - reading.percent
        return distance <= 3 ? 20 : distance <= 10 ? 60 : 180
    }

    private func apply(_ next: ChargeOutput) {
        guard next != output || actuator.current() != next else { return }
        do {
            // Record intent first, so a crash mid-write still triggers a restore.
            if next != .normal { try? marker.save(next) }
            try actuator.apply(next)
            if next == .normal { marker.remove() }
            if next != output {
                log.notice("charging \(next.chargingAllowed ? "on" : "off"), adapter \(next.adapterOn ? "on" : "off")")
            }
            output = next
            lastError = nil
        } catch {
            lastError = "\(error)"
            log.error("apply failed: \(String(describing: error))")
        }
    }
}
