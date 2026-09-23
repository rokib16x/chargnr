/// What the user asked for. Stored by the helper and shared with the app and CLI.
public struct ChargeConfig: Codable, Equatable, Sendable {
    /// Stop charging at this percentage. 100 means no limit.
    public var limit: Int
    /// Start again once the battery drops this many points below the limit.
    public var gap: Int

    public init(limit: Int = 100, gap: Int = 5) {
        self.limit = limit
        self.gap = gap
    }

    public static let limitRange = 20...100
    public static let gapRange = 1...20
    /// The adapter method drains the battery between switches, so a narrower
    /// band would mean many tiny cycles.
    public static let minimumAdapterGap = 3

    public var isLimited: Bool { limit < 100 }

    /// The value clamped into supported ranges.
    public var normalized: ChargeConfig {
        ChargeConfig(limit: min(max(limit, Self.limitRange.lowerBound), Self.limitRange.upperBound),
                     gap: min(max(gap, Self.gapRange.lowerBound), Self.gapRange.upperBound))
    }

    /// Lowest percentage before charging resumes.
    public var resumeBelow: Int { max(limit - gap, Self.limitRange.lowerBound - 1) }
}
