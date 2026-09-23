import Foundation
import os

/// A battery reading the controller acts on.
public struct BatteryReading: Equatable, Sendable {
    public var percent: Int
    public var pluggedIn: Bool

    public init(percent: Int, pluggedIn: Bool) {
        self.percent = percent
        self.pluggedIn = pluggedIn
    }

    /// Reads the SMC, which answers even when IOKit's battery service lags.
    public static func read(_ smc: some SMCTransport) -> BatteryReading? {
        let state = ChargeState.read(smc, Capabilities(charging: .unsupported, canInhibit: false,
                                                       adapterKey: nil, magSafeLED: false, temperature: false))
        guard let percent = state.percent, let plugged = state.pluggedIn else { return nil }
        return BatteryReading(percent: percent, pluggedIn: plugged)
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
    private let log = Logger(subsystem: Chargnr.helperID, category: "controller")

    public private(set) var config: ChargeConfig
    private var output = ChargeOutput.normal
    private var reading: BatteryReading?
    private var lastError: String?

    public init(actuator: Actuator,
                configFile: JSONFile<ChargeConfig> = JSONFile(HelperPaths.config),
                marker: JSONFile<ChargeOutput> = JSONFile(HelperPaths.dirtyMarker),
                readBattery: @escaping @Sendable () -> BatteryReading?) {
        self.actuator = actuator
        self.configFile = configFile
        self.marker = marker
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
            let next = ChargePolicy.decide(config: config, method: method, percent: reading.percent,
                                           pluggedIn: reading.pluggedIn, previous: output)
            apply(next)
        }
        return interval
    }

    public func setConfig(_ new: ChargeConfig) throws {
        let new = new.normalized
        try configFile.save(new)
        config = new
        log.notice("config: limit \(new.limit)% gap \(new.gap), method \(self.method.rawValue)")
        tick()
    }

    /// Before sleep nothing can switch the adapter back on, so a cut adapter
    /// would drain the battery. Restore it; macOS's own limit (set to 80% by
    /// the app for sub-80 limits) keeps sleep charging in check. With charge
    /// keys, stop charging instead so the Mac cannot creep past the limit.
    public func willSleep() {
        switch method {
        case .adapter:
            apply(.normal)
        case .inhibit:
            apply(ChargeOutput(chargingAllowed: false, adapterOn: true))
        case .none:
            break
        }
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
                     percent: reading?.percent, pluggedIn: reading?.pluggedIn, lastError: lastError,
                     nextCheck: Int(interval))
    }

    /// How long until the next check. Far from the limit the battery takes
    /// minutes to move a point, so checking often would only waste wakeups.
    /// Power-source events trigger extra checks in between.
    public var interval: TimeInterval {
        guard method != .none, let reading else { return 300 }
        if output != .normal { return 20 }
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
