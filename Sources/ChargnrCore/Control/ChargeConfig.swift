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

    public init(limit: Int = 100, gap: Int = ChargeConfig.defaultGap, heatLimit: Int? = nil) {
        self.limit = limit
        self.gap = gap
        self.heatLimit = heatLimit
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
    }

    enum CodingKeys: String, CodingKey {
        case limit, gap, heatLimit
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ChargeConfig()
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? defaults.limit
        gap = try c.decodeIfPresent(Int.self, forKey: .gap) ?? defaults.gap
        heatLimit = try c.decodeIfPresent(Int.self, forKey: .heatLimit)
    }
}
