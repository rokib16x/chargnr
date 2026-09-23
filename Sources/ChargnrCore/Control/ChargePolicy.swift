/// How the helper holds the battery at the limit on this Mac.
public enum ControlMethod: String, Codable, Sendable {
    /// Leave everything to the hardware: no limit, or the firmware / macOS
    /// limit is doing the work.
    case none
    /// Switch charging off and on (CH0B/CH0C or CHTE).
    case inhibit
    /// Switch wall power off and on, running from battery above the limit.
    case adapter

    /// Picks the method for `config` on a Mac with `caps`. Limits of 80% and
    /// more on gated firmware go to macOS's own limit, which the app sets, so
    /// the helper stays out of the way.
    public static func choose(for config: ChargeConfig, caps: Capabilities) -> ControlMethod {
        guard config.isLimited else { return .none }
        switch caps.charging {
        case .tahoe, .legacy:
            return .inhibit
        case .firmwareLimit:
            return caps.canInhibit ? .inhibit : .none
        case .gated, .unsupported:
            if config.limit >= NativeLimitRange.minimum { return .none }
            return caps.canDisableAdapter ? .adapter : .none
        }
    }
}

public enum NativeLimitRange {
    /// macOS rejects anything lower (PowerUI error code 4).
    public static let minimum = 80
}

/// The switches the helper wants set right now.
public struct ChargeOutput: Codable, Equatable, Sendable {
    public var chargingAllowed: Bool
    public var adapterOn: Bool

    public static let normal = ChargeOutput(chargingAllowed: true, adapterOn: true)

    public init(chargingAllowed: Bool, adapterOn: Bool) {
        self.chargingAllowed = chargingAllowed
        self.adapterOn = adapterOn
    }
}

/// The charge-limit decision, as a pure function so it can be tested without hardware.
public enum ChargePolicy {
    /// - Parameters:
    ///   - percent: current battery percentage.
    ///   - pluggedIn: whether a charger is connected.
    ///   - previous: what was decided last time; inside the band between
    ///     `resumeBelow` and `limit` the previous choice is kept (hysteresis).
    public static func decide(config: ChargeConfig, method: ControlMethod,
                              percent: Int, pluggedIn: Bool,
                              previous: ChargeOutput) -> ChargeOutput {
        let config = config.normalized
        switch method {
        case .none:
            return .normal

        case .inhibit:
            // Nothing to hold on battery; allow charging so plugging in just works.
            guard pluggedIn else { return .normal }
            if percent >= config.limit { return ChargeOutput(chargingAllowed: false, adapterOn: true) }
            if percent <= config.resumeBelow { return .normal }
            return ChargeOutput(chargingAllowed: previous.chargingAllowed, adapterOn: true)

        case .adapter:
            // With the adapter off the Mac reads as unplugged, so remember the
            // previous state instead of trusting `pluggedIn` alone.
            guard pluggedIn || !previous.adapterOn else { return .normal }
            let gap = max(config.gap, ChargeConfig.minimumAdapterGap)
            if percent >= config.limit { return ChargeOutput(chargingAllowed: true, adapterOn: false) }
            if percent <= max(config.limit - gap, ChargeConfig.limitRange.lowerBound - 1) { return .normal }
            return ChargeOutput(chargingAllowed: true, adapterOn: previous.adapterOn)
        }
    }
}
