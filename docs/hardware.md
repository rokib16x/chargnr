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
| **20457.1.x (macOS 27)** | **gated** (see below) | `CHIE` | `ACLC` |

### Firmware limit (bfF0 / bfD0 / bfE0)

- `bfD0` upper and `bfE0` lower are ui32 percentages stored **little-endian**
  (80% = `50 00 00 00`), unlike most SMC integers.
- `bfF0` is 1 byte, `02` when the limit is active.
- Write order: `bfF0 = 00`, upper, lower, then `bfF0 = 02`.
- The firmware enforces the range itself, including during sleep. Above the
  limit it may run the Mac from the battery.

### Firmware 20457.1.x: charge keys gated (confirmed 2026-09-23)

Tested on Mac16,8 (M4 Pro), firmware 20457.1.29, macOS 27.0. The same change
shipped from macOS 27 beta 4 (firmware 20457.0.125.0.2) and in the macOS 15.8 /
26.7 security updates.

| Key | Result |
|---|---|
| `bfF0`, `bfD0`, `bfE0` | still listed by `#KEY`, but key info, read and write all fail with `kIOReturnNotPrivileged` (`0xe00002c1`), even as root |
| `CH0J` | same: `kIOReturnNotPrivileged` |
| `CH0B`, `CH0C`, `CHTE`, `CH0I` | not accessible (reported elsewhere as zero-size placeholders) |
| `CHIE` | readable, and reported writable as root: the adapter switch still works |
| `ACLC`, `BUIC`, `AC-W`, `TB0T` | readable |

AppleSMC now filters these keys in its user client. The gate is reported as the
private entitlement `com.apple.private.iokit.soc-limit`, which third-party apps
cannot get. `IOPSCopyBatteryLevelLimits()` is gated the same way.
chargnr reports this state as `ChargingMethod.gated`.

What still works on this firmware:

1. **macOS's own charge limit via PowerUI** (no root). Private framework
   `/System/Library/PrivateFrameworks/PowerUI.framework`, class
   `PowerUISmartChargeClient`, created with `initWithClientName:`.
   Read-only calls confirmed on this Mac:
   - `isMCLSupported` → `B16@0:8` → YES
   - `isMCLCurrentlyEnabled:` → `Q24@0:8^@16`
   - `getMCLLimitWithError:` → `C24@0:8^@16` (100 when off)
   - `availableChargeLimitsWithError:` → `@24@0:8^@16` → `[80, 85, 90, 95, 100]`
   Write calls, not tested yet: `setMCLLimit:error:` (`B28@0:8C16^@20`),
   `enableMCL:`, `disableMCL:`, `temporarilyDisableMCL:` (top up; does not clear
   itself on full charge or unplug), `temporarilyOverrideMCLTargetSoC:error:`
   (`B28@0:8C16^@20`, unknown whether it accepts values below 80).
   Limits below 80% are reported impossible through this API.
2. **Adapter cut-off** (root). Write `CHIE = 08` at the upper limit so the Mac
   runs on battery, `CHIE = 00` at the lower limit. Allows any limit, but only
   while chargnr is awake to switch it, adds shallow cycles, and must restore
   the adapter on exit, crash and before sleep.

MCL = managed charge limit, OBC = optimized battery charging, DEoC = the
"desktop end of charge" mode.

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
