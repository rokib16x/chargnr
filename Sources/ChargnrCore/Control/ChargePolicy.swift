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

/// Everything a decision depends on.
public struct PolicyInput: Sendable {
    public var config: ChargeConfig
    public var method: ControlMethod
    public var percent: Int
    public var pluggedIn: Bool
    /// Heat protection is holding (the controller handles hysteresis and cooldown).
    public var hot: Bool = false
    /// Force discharge is active and the battery is still above its target.
    public var discharging: Bool = false
    public var canInhibit: Bool
    public var canCutAdapter: Bool
    public var previous: ChargeOutput

    public init(config: ChargeConfig, method: ControlMethod, percent: Int, pluggedIn: Bool,
                hot: Bool = false, discharging: Bool = false,
                canInhibit: Bool, canCutAdapter: Bool, previous: ChargeOutput) {
        self.config = config
        self.method = method
        self.percent = percent
        self.pluggedIn = pluggedIn
        self.hot = hot
        self.discharging = discharging
        self.canInhibit = canInhibit
        self.canCutAdapter = canCutAdapter
        self.previous = previous
    }
}

/// The charging decision, as a pure function so it can be tested without hardware.
public enum ChargePolicy {
    /// Force discharge wins over everything; then heat, which only ever
    /// switches things off; then the limit.
    public static func decide(_ input: PolicyInput) -> ChargeOutput {
        if input.discharging && input.canCutAdapter {
            return ChargeOutput(chargingAllowed: true, adapterOn: false)
        }
        var output = decide(config: input.config, method: input.method, percent: input.percent,
                            pluggedIn: input.pluggedIn, previous: input.previous)
        if input.hot && (input.pluggedIn || !input.previous.adapterOn) {
            // Stopping charging keeps the Mac on wall power, so prefer it.
            if input.canInhibit { output.chargingAllowed = false }
            else if input.canCutAdapter { output.adapterOn = false }
        }
        return output
    }

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
