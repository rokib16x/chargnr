<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/chargnr-wordmark-dark.png">
    <img src="docs/brand/chargnr-wordmark.png" alt="chargnr" width="360">
  </picture>
</p>

<p align="center">Keep your MacBook battery healthy.<br>
A free, open-source menu bar app that stops charging at the level you choose.</p>

## Features

- **Charge limit** from 20 to 100%, with **sailing**: let the battery drift a
  few points below the limit before charging again
- **Heat protection**: pause charging while the battery is hot
- **Top up** to 100% once, then back to the limit
- **Force discharge** while plugged in, down to a target
- **Calibration**: discharge, charge to full, hold, then back to the limit,
  on demand or on a schedule
- **30 days of history**, with a 24-hour chart in the menu
- **Stops charging during sleep** where the Mac allows it, and never leaves
  the charger switched off while asleep
- **MagSafe light** control on Macs that allow it
- A **`chargnr` command-line tool** and **Shortcuts** actions
- Works on **macOS 27** firmware, where Apple locked the old charging switches:
  limits of 80% and above go through macOS's own limit, lower limits switch the
  charger off at the limit

Apple Silicon only, macOS 14 or later.

## Install

Download the DMG from [Releases](https://github.com/rokib16x/chargnr/releases),
or with Homebrew:

```sh
brew install --cask rokib16x/chargnr/chargnr
```

Open chargnr from the menu bar and install its helper when asked. The helper is
a small background service that switches charging; it needs your approval once.

## Command line

```sh
chargnr status            # battery, charging state, what this Mac supports
chargnr limit 80          # stop charging at 80%
chargnr sailing 5         # resume below 75%
chargnr heat 35           # pause charging at 35 °C
chargnr topup             # charge to 100% once
chargnr discharge 50      # run from battery down to 50%
chargnr calibrate         # full calibration cycle
chargnr history           # last 24 hours
chargnr help              # everything else
```

## Build

```sh
swift build && swift test   # core, CLI, helper, tests
make run                    # build and open the menu bar app (needs XcodeGen)
```

## How it works

[docs/hardware.md](docs/hardware.md) covers the SMC keys each firmware exposes
and what changed on macOS 27. [docs/helper.md](docs/helper.md) covers the
helper: how limits are enforced, the safety rules, and who may talk to it.

## Credits

chargnr is written from scratch. These projects were studied to learn how Apple
Silicon charging control works (no code is copied):

- [batt](https://github.com/charlie0129/batt) by charlie0129
- [OpenDente](https://github.com/killerk3emstar/OpenDente) by killerk3emstar

## License

MIT
