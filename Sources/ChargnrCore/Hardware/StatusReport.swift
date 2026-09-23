/// Everything `chargnr status` shows, in one Codable value for `--json`.
public struct StatusReport: Codable, Sendable {
    public let version: String
    public let model: String?
    public let firmware: String?
    public let macOS: String
    public let capabilities: Capabilities
    public let charge: ChargeState
    public let battery: BatteryInfo?

    public static func collect(smc: some SMCTransport, battery: BatteryInfo?) -> StatusReport {
        let caps = Capabilities.detect(smc)
        return StatusReport(
            version: Chargnr.version,
            model: SystemInfo.modelIdentifier(),
            firmware: SystemInfo.firmwareVersion(),
            macOS: SystemInfo.osVersion,
            capabilities: caps,
            charge: ChargeState.read(smc, caps),
            battery: battery
        )
    }
}
