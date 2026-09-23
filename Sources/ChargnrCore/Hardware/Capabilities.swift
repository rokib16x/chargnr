/// How this Mac lets software stop charging.
public enum ChargingMethod: String, Codable, Sendable {
    /// macOS 27-era firmware limit (bfF0/bfD0/bfE0). The firmware enforces it.
    case firmwareLimit
    /// Tahoe-era inhibit key (CHTE). chargnr has to switch charging on and off.
    case tahoe
    /// Older inhibit keys (CH0B + CH0C).
    case legacy
    /// The firmware limit keys exist but AppleSMC refuses them to anything
    /// without Apple's private entitlement (firmware 20457.1+). Charging can
    /// still be limited through macOS's own limit or by cutting the adapter.
    case gated
    case unsupported

    public var summary: String {
        switch self {
        case .firmwareLimit: "firmware charge limit (macOS 27 era)"
        case .tahoe: "charge inhibit, Tahoe-era firmware"
        case .legacy: "charge inhibit, older firmware"
        case .gated: "charge keys locked by Apple (firmware 20457.1+)"
        case .unsupported: "not supported"
        }
    }
}

/// What chargnr can control on this Mac, found by probing SMC keys.
public struct Capabilities: Codable, Equatable, Sendable {
    public let charging: ChargingMethod
    /// True when the Tahoe/legacy inhibit keys also exist next to a firmware
    /// limit, so manual inhibit (top up, discharge, heat) is still possible.
    public let canInhibit: Bool
    public let adapterKey: SMCKey?
    public let magSafeLED: Bool
    public let temperature: Bool

    public var canDisableAdapter: Bool { adapterKey != nil }

    public static func detect(_ smc: some SMCTransport) -> Capabilities {
        let firmware = [SMCKeys.firmwareLimitActive, SMCKeys.firmwareLimitUpper, SMCKeys.firmwareLimitLower]
            .allSatisfy(smc.exists)
        let tahoe = smc.exists(SMCKeys.chargeInhibitTahoe)
        let legacy = smc.exists(SMCKeys.chargeInhibitB) && smc.exists(SMCKeys.chargeInhibitC)

        // The firmware limit wins: it keeps working while the Mac sleeps and
        // needs no babysitting from a daemon.
        let gated = smc.probe(SMCKeys.firmwareLimitActive) == .gated
        let method: ChargingMethod =
            firmware ? .firmwareLimit : tahoe ? .tahoe : legacy ? .legacy : gated ? .gated : .unsupported

        return Capabilities(
            charging: method,
            canInhibit: tahoe || legacy,
            adapterKey: SMCKeys.adapterKeys.first(where: smc.exists),
            magSafeLED: smc.exists(SMCKeys.magSafeLED),
            temperature: smc.exists(SMCKeys.batteryTemperature)
        )
    }
}
