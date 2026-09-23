/// The firmware-managed charge range on macOS 27-era firmware.
public struct FirmwareLimit: Codable, Equatable, Sendable {
    public let active: Bool
    public let lower: Int
    public let upper: Int

    public static let activeFlag: UInt8 = 0x02

    /// Encodes a percentage the way bfD0/bfE0 expect it: ui32 little-endian.
    public static func encode(_ percent: Int) -> [UInt8] {
        withUnsafeBytes(of: UInt32(clamping: percent).littleEndian, Array.init)
    }

    static func decode(_ bytes: [UInt8]) -> Int? {
        guard bytes.count == 4 else { return nil }
        return Int(bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) })
    }
}

/// Charging controls as the SMC reports them right now.
public struct ChargeState: Codable, Equatable, Sendable {
    public let percent: Int?
    public let pluggedIn: Bool?
    /// True when chargnr (or another tool) has charging switched off.
    public let chargingInhibited: Bool?
    public let adapterDisabled: Bool?
    public let firmwareLimit: FirmwareLimit?
    public let magSafeLED: UInt8?
    public let temperatureC: Double?

    public static func read(_ smc: some SMCTransport, _ caps: Capabilities) -> ChargeState {
        func byte(_ key: SMCKey) -> UInt8? { (try? smc.read(key))?.first }

        let inhibited: Bool? = switch true {
        case smc.exists(SMCKeys.chargeInhibitTahoe): byte(SMCKeys.chargeInhibitTahoe).map { $0 != 0 }
        case smc.exists(SMCKeys.chargeInhibitB): byte(SMCKeys.chargeInhibitB).map { $0 != 0 }
        default: nil
        }

        var limit: FirmwareLimit?
        if caps.charging == .firmwareLimit,
           let flag = byte(SMCKeys.firmwareLimitActive),
           let upper = (try? smc.read(SMCKeys.firmwareLimitUpper)).flatMap(FirmwareLimit.decode),
           let lower = (try? smc.read(SMCKeys.firmwareLimitLower)).flatMap(FirmwareLimit.decode) {
            limit = FirmwareLimit(active: flag == FirmwareLimit.activeFlag, lower: lower, upper: upper)
        }

        return ChargeState(
            percent: byte(SMCKeys.batteryPercent).map(Int.init),
            pluggedIn: byte(SMCKeys.acPower).map { Int8(bitPattern: $0) > 0 },
            chargingInhibited: inhibited,
            adapterDisabled: caps.adapterKey.flatMap(byte).map { $0 != 0 },
            firmwareLimit: limit,
            magSafeLED: caps.magSafeLED ? byte(SMCKeys.magSafeLED) : nil,
            temperatureC: caps.temperature ? readTemperature(smc) : nil
        )
    }

    private static func readTemperature(_ smc: some SMCTransport) -> Double? {
        guard let info = try? smc.keyInfo(SMCKeys.batteryTemperature),
              let bytes = try? smc.read(SMCKeys.batteryTemperature) else { return nil }
        let value: Double? = switch (info.type.description, bytes.count) {
        case ("flt ", 4):
            // SMC floats are stored in host (little-endian) order.
            Double(Float(bitPattern: bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }))
        case ("sp78", 2):
            // Signed fixed point, 8 fraction bits, big-endian.
            Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            nil
        }
        // Reject readings no battery produces; some Macs report 0 or garbage.
        return value.flatMap { (1...90).contains($0) ? $0 : nil }
    }
}
