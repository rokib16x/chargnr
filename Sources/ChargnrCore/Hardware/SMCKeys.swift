/// Every SMC key chargnr touches, with the values each one takes.
///
/// Which keys a Mac has depends on its firmware, not its macOS version, so
/// `Capabilities.detect` probes for them instead of checking the OS.
public enum SMCKeys {
    // Charging, older firmware (M1–M3 era). 1 byte each: 0x00 allow, 0x02 inhibit.
    public static let chargeInhibitB: SMCKey = "CH0B"
    public static let chargeInhibitC: SMCKey = "CH0C"
    // Charging, macOS 26 Tahoe-era firmware. 4 bytes: 00 00 00 00 allow, 01 00 00 00 inhibit.
    public static let chargeInhibitTahoe: SMCKey = "CHTE"

    // Firmware charge limit, macOS 27-era firmware. The firmware keeps the battery
    // between lower and upper by itself, including while the Mac sleeps.
    /// 1 byte: 0x02 when the limit is active.
    public static let firmwareLimitActive: SMCKey = "bfF0"
    /// ui32 percent, little-endian (unlike most SMC integers).
    public static let firmwareLimitUpper: SMCKey = "bfD0"
    /// ui32 percent, little-endian.
    public static let firmwareLimitLower: SMCKey = "bfE0"

    // Adapter (run from battery while plugged in). Probed in this order.
    // CH0I and CH0J: 0x00 adapter on, 0x01 off. CHIE: 0x00 on, 0x08 off.
    public static let adapterKeys: [SMCKey] = ["CH0I", "CH0J", "CHIE"]

    /// MagSafe LED: 0 system, 1 off, 3 green, 4 orange.
    public static let magSafeLED: SMCKey = "ACLC"

    /// Battery percentage as shown to the user, 1 byte.
    public static let batteryPercent: SMCKey = "BUIC"
    /// AC power present, signed 1 byte, > 0 when plugged in.
    public static let acPower: SMCKey = "AC-W"
    /// Battery temperature. Type varies by Mac (`flt ` or `sp78`).
    public static let batteryTemperature: SMCKey = "TB0T"
}
