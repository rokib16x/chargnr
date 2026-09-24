# Changelog

## 0.2.0

First release.

- **Charge limit** from 20 to 100% with **sailing**, from the menu bar, the
  `chargnr` CLI or Shortcuts.
- **macOS 27 support.** Firmware 20457.1+ locks the SMC charging keys. chargnr
  uses macOS's own charge limit for 80% and above (also during sleep) and
  switches the charger off at the limit below 80%.
- **Heat protection**, **top up**, **force discharge** and **calibration** with
  an optional schedule.
- **History**: the helper records 30 days of battery level, charging and
  temperature; the menu shows the last 24 hours.
- **Safety**: every write is read back; charging goes back to normal if the
  helper stops, crashes or is removed; the charger is never left switched off
  while the Mac sleeps or below 10%.
- **MagSafe light** control where the Mac allows it.
