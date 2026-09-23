/// Everything `chargnr status` shows, in one Codable value for `--json`.
public struct StatusReport: Codable, Sendable {
    public let version: String
    public let model: String?
    public let firmware: String?
    public let macOS: String
    public let capabilities: Capabilities
    public let charge: ChargeState
    public let battery: BatteryInfo?
    /// macOS's built-in limit; nil for fake runs or when unavailable.
    public let nativeLimit: NativeChargeLimit?

    public static func collect(smc: some SMCTransport, battery: BatteryInfo?,
                               nativeLimit: NativeChargeLimit?) -> StatusReport {
        let caps = Capabilities.detect(smc)
        return StatusReport(
            version: Chargnr.version,
            model: SystemInfo.modelIdentifier(),
            firmware: SystemInfo.firmwareVersion(),
            macOS: SystemInfo.osVersion,
            capabilities: caps,
            charge: ChargeState.read(smc, caps),
            battery: battery,
            nativeLimit: nativeLimit
        )
    }
}
