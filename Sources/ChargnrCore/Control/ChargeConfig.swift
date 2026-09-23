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

    public init(limit: Int = 100, gap: Int = ChargeConfig.defaultGap) {
        self.limit = limit
        self.gap = gap
    }

    public static let limitRange = 20...100
    public static let gapRange = 1...20
    public static let defaultGap = 5
    /// Sailing off: resume as soon as the battery drops one point.
    public static let noSailingGap = 1
    /// The adapter method drains the battery between switches, so a narrower
    /// band would mean many tiny cycles.
    public static let minimumAdapterGap = 3

    public var isLimited: Bool { limit < 100 }

    /// The value clamped into supported ranges.
    public var normalized: ChargeConfig {
        var copy = self
        copy.limit = min(max(limit, Self.limitRange.lowerBound), Self.limitRange.upperBound)
        copy.gap = min(max(gap, Self.gapRange.lowerBound), Self.gapRange.upperBound)
        return copy
    }

    /// Lowest percentage before charging resumes.
    public var resumeBelow: Int { max(limit - gap, Self.limitRange.lowerBound - 1) }

    enum CodingKeys: String, CodingKey {
        case limit, gap
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ChargeConfig()
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? defaults.limit
        gap = try c.decodeIfPresent(Int.self, forKey: .gap) ?? defaults.gap
    }
}
