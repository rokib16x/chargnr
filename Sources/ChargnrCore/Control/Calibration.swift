import Foundation

/// A battery calibration run: discharge low, charge to full, hold at full,
/// then return to the normal limit. This gives the battery gauge a full cycle
/// to re-learn its capacity after long stretches at a limit.
public struct Calibration: Codable, Equatable, Sendable {
    public enum Step: String, Codable, Sendable {
        case discharge, charge, hold
    }

    public var step: Step
    public var dischargeTo: Int
    public var holdMinutes: Int
    public var startedAt: Date
    /// When the battery reached 100% and holding began.
    public var fullSince: Date?

    public static let defaultDischargeTo = 15
    public static let defaultHoldMinutes = 60
    public static let dischargeRange = 10...50
    public static let holdRange = 0...240
    /// A run that has not finished by then (charger unplugged for hours,
    /// firmware refusing to charge) is abandoned.
    public static let timeout: TimeInterval = 24 * 60 * 60

    public init(dischargeTo: Int = defaultDischargeTo, holdMinutes: Int = defaultHoldMinutes, startedAt: Date) {
        self.step = .discharge
        self.dischargeTo = min(max(dischargeTo, Self.dischargeRange.lowerBound), Self.dischargeRange.upperBound)
        self.holdMinutes = min(max(holdMinutes, Self.holdRange.lowerBound), Self.holdRange.upperBound)
        self.startedAt = startedAt
    }

    /// What happens next, given the battery right now.
    public enum Advance: Equatable, Sendable {
        case stay
        case moveTo(Calibration)
        case finished
        case abandoned
    }

    public func advance(percent: Int, at now: Date) -> Advance {
        if now.timeIntervalSince(startedAt) > Self.timeout { return .abandoned }
        var next = self
        switch step {
        case .discharge:
            guard percent <= dischargeTo else { return .stay }
            next.step = .charge
        case .charge:
            guard percent >= 100 else { return .stay }
            next.step = .hold
            next.fullSince = now
        case .hold:
            guard now.timeIntervalSince(fullSince ?? now) >= TimeInterval(holdMinutes * 60) else { return .stay }
            return .finished
        }
        return .moveTo(next)
    }
}

/// Runs calibration every so many days, starting at a set hour once the Mac is plugged in.
public struct CalibrationSchedule: Codable, Equatable, Sendable {
    public var everyDays: Int
    /// Local hour of day (0–23) from which a due run may start.
    public var hour: Int

    public static let everyDaysRange = 7...90

    public init(everyDays: Int, hour: Int) {
        self.everyDays = min(max(everyDays, Self.everyDaysRange.lowerBound), Self.everyDaysRange.upperBound)
        self.hour = min(max(hour, 0), 23)
    }

    /// The next time a run may start after `last`.
    public func nextRun(after last: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.date(byAdding: .day, value: everyDays, to: last) ?? last
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }
}
