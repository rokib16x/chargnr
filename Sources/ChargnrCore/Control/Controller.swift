import Foundation
import os

/// A battery reading the controller acts on.
public struct BatteryReading: Equatable, Sendable {
    public var percent: Int
    public var pluggedIn: Bool
    public var temperatureC: Double?
    /// Whether the battery is taking charge (IOKit), when known.
    public var isCharging: Bool?
    /// Battery power in milliwatts (IOKit), for history.
    public var batteryMW: Int?
    /// The lid is closed (clamshell mode with an external display).
    public var lidClosed: Bool

    public init(percent: Int, pluggedIn: Bool, temperatureC: Double? = nil, isCharging: Bool? = nil,
                batteryMW: Int? = nil, lidClosed: Bool = false) {
        self.percent = percent
        self.pluggedIn = pluggedIn
        self.temperatureC = temperatureC
        self.isCharging = isCharging
        self.batteryMW = batteryMW
        self.lidClosed = lidClosed
    }

    /// Reads the SMC, which answers even when IOKit's battery service lags.
    public static func read(_ smc: some SMCTransport) -> BatteryReading? {
        let state = ChargeState.read(smc, Capabilities(charging: .unsupported, canInhibit: false, adapterKey: nil,
                                                       magSafeLED: false, temperature: smc.exists(SMCKeys.batteryTemperature)))
        guard let percent = state.percent, let plugged = state.pluggedIn else { return nil }
        let info = BatteryInfo.current()
        return BatteryReading(percent: percent, pluggedIn: plugged, temperatureC: state.temperatureC,
                              isCharging: info?.isCharging, batteryMW: info?.batteryPowerMW,
                              lidClosed: SystemInfo.isLidClosed())
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
    /// The lid is closed, so chargnr is keeping the charger on.
    public var lidClosed: Bool?
    public var topUpUntil: Date?
    public var dischargeTo: Int?
    public var calibration: Calibration?
    public var nextCalibration: Date?
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
    private let history: HistoryStore?
    private let log: Logger

    public private(set) var config: ChargeConfig
    private var output = ChargeOutput.normal
    private var reading: BatteryReading?
    private var lastError: String?
    /// When heat protection started holding, or nil when it is not.
    private var hotSince: Date?
    /// Set once an LED write fails, so a Mac that refuses it is not retried every tick.
    private var ledRefused: String?

    public init(actuator: Actuator,
                configFile: JSONFile<ChargeConfig> = JSONFile(HelperPaths.config),
                marker: JSONFile<ChargeOutput> = JSONFile(HelperPaths.dirtyMarker),
                now: @escaping @Sendable () -> Date = Date.init,
                log: Logger = Logger(subsystem: Chargnr.helperID, category: "controller"),
                history: HistoryStore? = nil,
                readBattery: @escaping @Sendable () -> BatteryReading?) {
        self.actuator = actuator
        self.history = history
        self.log = log
        self.configFile = configFile
        self.marker = marker
        self.now = now
        self.readBattery = readBattery
        config = configFile.load()?.normalized ?? ChargeConfig()
    }

    public var method: ControlMethod {
        ControlMethod.choose(for: config.effective(at: now()), caps: actuator.caps)
    }

    /// Call once at launch. If the last run left switches changed (crash,
    /// kill -9, power loss), put them back before doing anything else.
    public func start() {
        if let left = marker.load() {
            log.notice("previous run left switches at \(String(describing: left), privacy: .public); restoring")
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
            let nativeBefore = config.nativeTarget(at: now())
            endTopUpIfDone(reading)
            endDischargeIfDone(reading)
            advanceCalibration(reading)
            startScheduledCalibration(reading)
            let nativeAfter = config.nativeTarget(at: now())
            if nativeAfter != nativeBefore { onNativeTargetChanged?(nativeAfter) }
            updateHeat(reading.temperatureC)
            let effective = config.effective(at: now())
            var next = ChargePolicy.decide(PolicyInput(
                config: effective, method: method, percent: reading.percent, pluggedIn: reading.pluggedIn,
                hot: hotSince != nil, discharging: config.dischargeTo != nil || config.calibration?.step == .discharge,
                lidClosed: reading.lidClosed, canInhibit: actuator.caps.canInhibit,
                canCutAdapter: actuator.caps.canDisableAdapter, previous: output))
            if ledRefused == nil {
                let charging = reading.isCharging
                    ?? (next.chargingAllowed && reading.percent < min(effective.limit, 100))
                next.led = MagSafeLED.value(for: config.led, pluggedIn: reading.pluggedIn,
                                            adapterOn: next.adapterOn, charging: charging)
            }
            apply(next)
            history?.record(HistorySample(
                time: now(), percent: reading.percent, pluggedIn: reading.pluggedIn,
                charging: reading.isCharging ?? (next.chargingAllowed && next.adapterOn && reading.pluggedIn),
                temperatureC: reading.temperatureC, batteryMW: reading.batteryMW,
                held: output.chargingAllowed == false || output.adapterOn == false))
        }
        return interval
    }

    /// Ends a top up once the battery is full, the charger is unplugged, or
    /// it has run out of time. A cut adapter reads as unplugged, but a top up
    /// never cuts it, so an unplugged reading here is a real unplug.
    private func endTopUpIfDone(_ reading: BatteryReading) {
        guard let until = config.topUpUntil else { return }
        let reason: String? =
            now() >= until ? "time ran out"
            : reading.percent >= 100 ? "battery full"
            : !reading.pluggedIn && output.adapterOn ? "charger unplugged"
            : nil
        guard let reason else { return }
        var ended = config
        ended.topUpUntil = nil
        try? configFile.save(ended)
        config = ended
        log.notice("top up ended: \(reason, privacy: .public)")
    }

    private func endDischargeIfDone(_ reading: BatteryReading) {
        guard let target = config.dischargeTo, reading.percent <= target || !actuator.caps.canDisableAdapter else { return }
        var ended = config
        ended.dischargeTo = nil
        try? configFile.save(ended)
        config = ended
        log.notice("discharge finished at \(reading.percent, privacy: .public)%")
    }

    /// True while a force discharge (or calibration's discharge step) is
    /// running, so the helper can keep the Mac awake: asleep, the adapter has
    /// to be back on and nothing drains.
    public var isDischarging: Bool {
        (config.dischargeTo != nil || config.calibration?.step == .discharge) && !output.adapterOn
    }

    /// Called with the new value whenever macOS's own limit should change
    /// (top up or calibration starting or ending), so the helper can set it.
    public var onNativeTargetChanged: (@Sendable (Int) -> Void)?

    private func save(_ change: (inout ChargeConfig) -> Void) {
        var next = config
        change(&next)
        try? configFile.save(next)
        config = next
    }

    private func advanceCalibration(_ reading: BatteryReading) {
        guard let run = config.calibration else { return }
        // Without an adapter switch the discharge step can only wait for use.
        switch run.advance(percent: reading.percent, at: now()) {
        case .stay:
            break
        case .moveTo(let next):
            save { $0.calibration = next }
            log.notice("calibration: \(next.step.rawValue, privacy: .public) at \(reading.percent, privacy: .public)%")
        case .finished:
            save {
                $0.calibration = nil
                $0.lastCalibration = now()
            }
            log.notice("calibration finished")
        case .abandoned:
            save { $0.calibration = nil }
            log.error("calibration abandoned after 24 hours")
        }
    }

    private func startScheduledCalibration(_ reading: BatteryReading) {
        guard let schedule = config.schedule, config.calibration == nil, reading.pluggedIn else { return }
        let last = config.lastCalibration ?? now()
        if config.lastCalibration == nil { save { $0.lastCalibration = last } }
        guard now() >= schedule.nextRun(after: last) else { return }
        startCalibration(Calibration(startedAt: now()))
        log.notice("scheduled calibration started")
    }

    /// Starts a run, replacing any top up or discharge.
    public func startCalibration(_ run: Calibration) {
        save {
            $0.calibration = run
            $0.topUpUntil = nil
            $0.dischargeTo = nil
        }
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
                log.notice("battery cooled to \(temperature, format: .fixed(precision: 1), privacy: .public) °C; heat protection off")
            }
        } else if temperature >= limit {
            hotSince = now()
            log.notice("battery at \(temperature, format: .fixed(precision: 1), privacy: .public) °C; pausing charging")
        }
    }

    public func setConfig(_ new: ChargeConfig) throws {
        let new = new.normalized
        try configFile.save(new)
        config = new
        if new.led == .system, lastError == ledRefused { lastError = nil }
        log.notice("config: limit \(new.limit, privacy: .public)% gap \(new.gap, privacy: .public) heat \(new.heatLimit.map { "\($0) °C" } ?? "off", privacy: .public), method \(self.method.rawValue, privacy: .public)")
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
            // Hand the LED back to macOS only if chargnr (now or in a crashed run) set it.
            if output.led != nil || marker.load()?.led != nil { try? actuator.setLED(MagSafeLED.system) }
            output = .normal
            marker.remove()
            lastError = nil
        } catch {
            lastError = "restore failed: \(error)"
            log.error("restore failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func status() -> HelperStatus {
        HelperStatus(version: Chargnr.version, config: config, method: method, output: output,
                     percent: reading?.percent, pluggedIn: reading?.pluggedIn,
                     temperatureC: reading?.temperatureC, heatHold: config.heatLimit == nil ? nil : hotSince != nil,
                     lidClosed: reading?.lidClosed,
                     topUpUntil: config.topUpUntil, dischargeTo: config.dischargeTo,
                     calibration: config.calibration,
                     nextCalibration: config.schedule.map { $0.nextRun(after: config.lastCalibration ?? now()) },
                     lastError: lastError,
                     nextCheck: Int(interval))
    }

    /// How long until the next check. Far from the limit the battery takes
    /// minutes to move a point, so checking often would only waste wakeups.
    /// Power-source events trigger extra checks in between.
    public var interval: TimeInterval {
        guard let reading else { return 300 }
        if output != .normal { return 20 }
        if config.topUpUntil != nil || config.calibration != nil { return 60 }
        // Temperature can climb within minutes while charging.
        if config.heatLimit != nil, reading.pluggedIn { return 60 }
        guard method != .none else { return 300 }
        let distance = config.limit - reading.percent
        return distance <= 3 ? 20 : distance <= 10 ? 60 : 180
    }

    private func apply(_ next: ChargeOutput) {
        guard next != output || !matchesHardware(next) else { return }
        var switches = next
        switches.led = nil
        do {
            // Record intent first, so a crash mid-write still triggers a restore.
            if next != .normal { try? marker.save(next) }
            try actuator.apply(switches)
            // Only worth reporting while an LED mode is still asked for.
            lastError = config.led == .system ? nil : ledRefused
        } catch {
            lastError = "\(error)"
            log.error("apply failed: \(String(describing: error), privacy: .public)")
            return
        }
        if switches.chargingAllowed != output.chargingAllowed || switches.adapterOn != output.adapterOn {
            log.notice("charging \(next.chargingAllowed ? "on" : "off", privacy: .public), adapter \(next.adapterOn ? "on" : "off", privacy: .public)")
        }
        switches.led = applyLED(next.led)
        output = switches
        if output == .normal { marker.remove() }
    }

    /// Sets the LED on its own, so a Mac that refuses LED writes keeps full
    /// charging control. Returns the value now owned, or nil for macOS.
    private func applyLED(_ led: UInt8?) -> UInt8? {
        guard let led else {
            // Leaving an LED mode: give the LED back to macOS once.
            if output.led != nil { try? actuator.setLED(MagSafeLED.system) }
            return nil
        }
        do {
            try actuator.setLED(led)
            return led
        } catch {
            ledRefused = "MagSafe LED control refused by this Mac (\(error))"
            lastError = ledRefused
            log.error("LED write failed (\(String(describing: error), privacy: .public)); LED control off until restart")
            return nil
        }
    }

    private func matchesHardware(_ target: ChargeOutput) -> Bool {
        let hardware = actuator.current()
        return hardware.chargingAllowed == target.chargingAllowed && hardware.adapterOn == target.adapterOn
            && (target.led == nil || hardware.led == target.led)
    }
}
