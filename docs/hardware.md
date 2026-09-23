# Hardware notes

What chargnr knows about Apple Silicon charge control, and where each fact was
confirmed. Which keys exist depends on the **firmware** version
(`system_profiler SPHardwareDataType | grep Firmware`), not the macOS version.
chargnr never branches on versions: it probes for keys at startup.

## Key sets

| Firmware | Stop charging | Adapter off | MagSafe LED |
|---|---|---|---|
| Older (M1–M3 era) | `CH0B` + `CH0C` = `02` (allow `00`) | `CH0I` = `01` | `ACLC` |
| Tahoe era | `CHTE` = `01 00 00 00` (allow `00 00 00 00`) | `CHIE` = `08` | `ACLC` |
| Early macOS 27 betas | `bfF0`/`bfD0`/`bfE0` firmware limit (see below) | `CHIE` | not controlled |
| **20457.1.x (macOS 27)** | **none found** | `CHIE` | `ACLC` |

### Firmware limit (bfF0 / bfD0 / bfE0)

- `bfD0` upper and `bfE0` lower are ui32 percentages stored **little-endian**
  (80% = `50 00 00 00`), unlike most SMC integers.
- `bfF0` is 1 byte, `02` when the limit is active.
- Write order: `bfF0 = 00`, upper, lower, then `bfF0 = 02`.
- The firmware enforces the range itself, including during sleep. Above the
  limit it may run the Mac from the battery.

### Firmware 20457.1.29 (confirmed on Mac16,8, M4 Pro, macOS 27.0, 2026-09-23)

`chargnr keys --all` lists 3335 keys. `CH0B`, `CH0C`, `CHTE`, `bfF0`, `bfD0`
and `bfE0` are all gone. `CHIE` (adapter) and `ACLC` (LED) remain. The `bf*`
range now holds `bfA0`–`bfL0` minus D/E/F, with no obvious limit semantics yet.
Until a replacement is found, this firmware is reported as unsupported and users
are pointed at the built-in limit in System Settings › Battery.

Open question: whether the built-in macOS limit can be driven from software.

## Battery data (IORegistry, AppleSmartBattery)

- On macOS 27, `DesignCapacity` and `NominalChargeCapacity` live inside the
  `BatteryData` dictionary; older releases have `DesignCapacity` and
  `AppleRawMaxCapacity` at the top level. chargnr reads both.
- `Temperature` is no longer in the registry on macOS 27; chargnr reads SMC
  `TB0T` (`flt ` little-endian, or `sp78` on some Macs).
- `PowerTelemetryData` has `SystemPowerIn` and `SystemLoad` in milliwatts.
- `Amperage` is a signed value stored as an unsigned 64-bit pattern.
- Firmware version: `IODeviceTree:/chosen` → `system-firmware-version`
  (`"mBoot-20457.1.29"`).

## SMC driver call

`IOConnectCallStructMethod` selector 2 on `AppleSMC`, with an 80-byte parameter
block: key at 0, data size at 28, data type at 32, result at 40, command at 42
(5 read, 6 write, 8 key at index, 9 key info), index at 44, data at 48 (max 32
bytes). Result `0x84` means the key does not exist. Writes need root.
