import Foundation

/// What the user asked for. Stored by the helper and shared with the app and CLI.
///
/// Decoding tolerates missing fields, so a config written by an older chargnr
/// still loads, and an older helper simply ignores fields it does not know.
public struct ChargeConfig: Codable, Equatable, Sendable {
    /// Stop charging at this percentage. 100 means no limit.
    public var limit: Int
    /// Sailing range: once at the limit, let the battery drift down this many
    /// points before charging again, instead of topping up every percent.
    public var gap: Int

    /// Pause charging while the battery is at or above this temperature (°C).
    /// nil turns heat protection off.
    public var heatLimit: Int?

    /// Charge to 100% once, ignoring the limit, until this time. Ends early
    /// when the battery is full or the charger is unplugged.
    public var topUpUntil: Date?

    /// Run from battery while plugged in until the battery is down to this
    /// percentage, then clear. nil when not discharging.
    public var dischargeTo: Int?

    public enum LEDMode: String, Codable, CaseIterable, Sendable {
        /// macOS decides (orange until 100%, even when a limit holds it lower).
        case system
        /// Orange while charging, green when the limit holds or the battery is full.
        case status
        /// Always off while plugged in.
        case off
    }

    public var led: LEDMode

    /// A calibration run in progress.
    public var calibration: Calibration?
    public var schedule: CalibrationSchedule?
    /// When the last calibration finished (or scheduling began), for the schedule.
    public var lastCalibration: Date?

    public init(limit: Int = 100, gap: Int = ChargeConfig.defaultGap, heatLimit: Int? = nil,
                topUpUntil: Date? = nil, dischargeTo: Int? = nil, led: LEDMode = .system,
                calibration: Calibration? = nil, schedule: CalibrationSchedule? = nil, lastCalibration: Date? = nil) {
        self.limit = limit
        self.gap = gap
        self.heatLimit = heatLimit
        self.topUpUntil = topUpUntil
        self.dischargeTo = dischargeTo
        self.led = led
        self.calibration = calibration
        self.schedule = schedule
        self.lastCalibration = lastCalibration
    }

    /// Calibration's charge and hold steps need the battery to reach 100%.
    public var calibrationNeedsFull: Bool {
        calibration.map { $0.step != .discharge } ?? false
    }

    public static let dischargeRange = 10...99

    /// A top up gives up after this long, so a forgotten one cannot keep the
    /// battery at 100% for days.
    public static let topUpMaximum: TimeInterval = 12 * 60 * 60

    public func isToppingUp(at date: Date = Date()) -> Bool {
        topUpUntil.map { date < $0 } ?? false
    }

    /// The config the policy should follow right now: no limit while topping
    /// up or while calibration charges and holds at full.
    public func effective(at date: Date = Date()) -> ChargeConfig {
        guard isToppingUp(at: date) || calibrationNeedsFull else { return self }
        var copy = self
        copy.limit = 100
        return copy
    }

    /// What macOS's own limit should be set to on gated firmware.
    public func nativeTarget(at date: Date = Date()) -> Int {
        let effective = effective(at: date)
        return effective.isLimited ? max(effective.limit, NativeLimitRange.minimum) : 100
    }

    public static let limitRange = 20...100
    public static let gapRange = 1...20
    public static let defaultGap = 5
    /// Sailing off: resume as soon as the battery drops one point.
    public static let noSailingGap = 1
    /// The adapter method drains the battery between switches, so a narrower
    /// band would mean many tiny cycles.
    public static let minimumAdapterGap = 3
    public static let heatLimitRange = 30...45
    /// Resume only once the battery is this many degrees below the heat limit…
    public static let heatHysteresis = 2.0
    /// …and at least this long after heat protection kicked in.
    public static let heatCooldown: TimeInterval = 5 * 60

    public var isLimited: Bool { limit < 100 }

    /// The value clamped into supported ranges.
    public var normalized: ChargeConfig {
        var copy = self
        copy.limit = min(max(limit, Self.limitRange.lowerBound), Self.limitRange.upperBound)
        copy.gap = min(max(gap, Self.gapRange.lowerBound), Self.gapRange.upperBound)
        copy.dischargeTo = dischargeTo.map { min(max($0, Self.dischargeRange.lowerBound), Self.dischargeRange.upperBound) }
        copy.heatLimit = heatLimit.map { min(max($0, Self.heatLimitRange.lowerBound), Self.heatLimitRange.upperBound) }
        return copy
    }

    /// Lowest percentage before charging resumes.
    public var resumeBelow: Int { max(limit - gap, Self.limitRange.lowerBound - 1) }

    /// True when the config asks for something only the helper can do on
    /// this Mac (macOS's own limit covers plain 80%+ limits on gated firmware).
    public func needsHelper(_ caps: Capabilities) -> Bool {
        ControlMethod.choose(for: self, caps: caps) != .none
            || (heatLimit != nil && (caps.canInhibit || caps.canDisableAdapter))
            // The helper ends a top up; without it macOS would stay at 100%.
            || (isToppingUp() && isLimited)
            || dischargeTo != nil
            || (led != .system && caps.magSafeLED)
            || calibration != nil || schedule != nil
    }

    enum CodingKeys: String, CodingKey {
        case limit, gap, heatLimit, topUpUntil, dischargeTo, led, calibration, schedule, lastCalibration
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ChargeConfig()
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? defaults.limit
        gap = try c.decodeIfPresent(Int.self, forKey: .gap) ?? defaults.gap
        heatLimit = try c.decodeIfPresent(Int.self, forKey: .heatLimit)
        topUpUntil = try c.decodeIfPresent(Date.self, forKey: .topUpUntil)
        dischargeTo = try c.decodeIfPresent(Int.self, forKey: .dischargeTo)
        led = (try? c.decodeIfPresent(LEDMode.self, forKey: .led)) ?? .system
        calibration = try? c.decodeIfPresent(Calibration.self, forKey: .calibration)
        schedule = try? c.decodeIfPresent(CalibrationSchedule.self, forKey: .schedule)
        lastCalibration = try c.decodeIfPresent(Date.self, forKey: .lastCalibration)
    }
}
