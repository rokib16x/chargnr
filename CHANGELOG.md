# Changelog

## 0.2.1

- **The menu opens in full.** It kept the size it had when first shown, so
  content that loaded a moment later (the 24-hour chart) pushed the top of the
  menu out of view. It now resizes with its content, and the chart keeps its
  space from the start so nothing jumps.
- **A solid background** for the menu: on macOS 27 the see-through glass let
  whatever was behind it wash out the text.
- The menu animates open.

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
