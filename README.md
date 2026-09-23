# chargnr

Keep your MacBook battery healthy. chargnr is a free, open-source menu bar app
that stops charging at the level you choose.

> **Status: early development.** Charging control, the helper and the menu bar
> app work; releases are not signed yet.

## Planned features

- Charge limit (20–100%) with sailing mode
- Heat protection, top up to 100%, force discharge
- Stop charging during sleep, and never overcharge if the app stalls
- MagSafe LED control
- Battery calibration with a schedule
- 30 days of battery history, with a 24-hour chart
- `chargnr` command-line tool and Shortcuts actions
- Works with macOS 27's firmware charge limit, macOS 26 Tahoe and older firmware

Apple Silicon only, macOS 14 or later.

## Build

```sh
swift build && swift test   # core, CLI, helper, tests
make run                    # build and open the menu bar app (needs XcodeGen)
```

## Credits

chargnr is written from scratch. These projects were studied to learn how Apple
Silicon charging control works (no code is copied):

- [batt](https://github.com/charlie0129/batt) by charlie0129
- [OpenDente](https://github.com/killerk3emstar/OpenDente) by killerk3emstar

## License

MIT
