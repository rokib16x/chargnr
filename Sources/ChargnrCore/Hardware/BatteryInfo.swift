import Foundation
import IOKit

/// Battery details from the IORegistry (AppleSmartBattery). No root needed.
public struct BatteryInfo: Codable, Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var externalConnected: Bool
    public var fullyCharged: Bool
    public var cycleCount: Int
    public var designCapacity: Int?
    /// Current full-charge capacity in mAh.
    public var fullChargeCapacity: Int?
    public var voltageMV: Int
    public var amperageMA: Int
    public var adapterWatts: Int?
    public var adapterName: String?
    /// Power coming in from the adapter, in milliwatts.
    public var systemPowerInMW: Int?
    /// Power the Mac is using, in milliwatts.
    public var systemLoadMW: Int?
    /// Minutes to empty or full; nil while macOS is still estimating.
    public var minutesRemaining: Int?
    public var notChargingReason: Int?

    /// Full-charge capacity against design capacity, in percent.
    public var healthPercent: Int? {
        guard let designCapacity, designCapacity > 0, let fullChargeCapacity else { return nil }
        return Int((Double(fullChargeCapacity) / Double(designCapacity) * 100).rounded())
    }

    /// Battery power in milliwatts: positive while charging, negative while discharging.
    public var batteryPowerMW: Int {
        voltageMV * amperageMA / 1000
    }

    /// Reads the internal battery, or nil on a Mac without one.
    public static func current() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        // Copy only the properties we use. The full dictionary includes large
        // blobs, so fetching it every poll would waste time and memory.
        func value(_ name: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        func int(_ any: Any?) -> Int? { (any as? NSNumber).map { Int($0.int64Value) } }
        func bool(_ name: String) -> Bool { (value(name) as? NSNumber)?.boolValue ?? false }

        guard let percent = int(value("CurrentCapacity")) else { return nil }
        let data = value("BatteryData") as? [String: Any]
        let adapter = value("AdapterDetails") as? [String: Any]
        let telemetry = value("PowerTelemetryData") as? [String: Any]
        let charger = value("ChargerData") as? [String: Any]
        let remaining = int(value("TimeRemaining"))

        return BatteryInfo(
            percent: percent,
            isCharging: bool("IsCharging"),
            externalConnected: bool("ExternalConnected"),
            fullyCharged: bool("FullyCharged"),
            cycleCount: int(value("CycleCount")) ?? 0,
            // macOS 27 moved these into BatteryData; older releases have them at the top.
            designCapacity: int(data?["DesignCapacity"]) ?? int(value("DesignCapacity")),
            fullChargeCapacity: int(data?["NominalChargeCapacity"]) ?? int(value("AppleRawMaxCapacity")),
            voltageMV: int(value("Voltage")) ?? 0,
            // Stored as an unsigned 64-bit pattern; int64Value restores the sign.
            amperageMA: int(value("Amperage")) ?? 0,
            adapterWatts: int(adapter?["Watts"]),
            adapterName: (adapter?["Name"] as? String)?.trimmingCharacters(in: .whitespaces),
            systemPowerInMW: int(telemetry?["SystemPowerIn"]),
            systemLoadMW: int(telemetry?["SystemLoad"]),
            minutesRemaining: remaining.flatMap { $0 == 0xFFFF ? nil : $0 },
            notChargingReason: int(charger?["NotChargingReason"])
        )
    }
}

public enum SystemInfo {
    /// The boot firmware version, e.g. "20457.1.29". It decides which SMC keys
    /// exist, and can be newer than the installed macOS.
    public static func firmwareVersion() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen")
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "system-firmware-version" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
        else { return nil }
        let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return text.split(separator: "-").last.map(String.init)
    }

    public static func modelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// True while the lid is closed (IOPMrootDomain `AppleClamshellState`).
    public static func isLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? NSNumber)?.boolValue ?? false
    }

    public static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
