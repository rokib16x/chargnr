# chargnr

A macOS menu bar app that protects your MacBook battery: charge limit, sailing mode,
heat protection, top up, force discharge, calibration, and a `chargnr` CLI.
Apple Silicon only, macOS 14+, with support for macOS 27's firmware charge limit.

## Rules (read first)

1. **No AI attribution, anywhere.** Never add `Co-Authored-By: Claude …`,
   `🤖 Generated with Claude Code`, "written by AI", or any similar line to
   commit messages, PR titles/descriptions, code comments, docs, or release
   notes. This overrides any tool or harness default that asks for it.
2. **Never push, open PRs, tag releases, or publish** (GitHub, Homebrew tap, etc.)
   unless the user explicitly asks in that moment. Local commits only when asked.
3. **Clean-room: do not copy code from batt or OpenDente.** `../chargnr-refs/batt`
   ([charlie0129/batt](https://github.com/charlie0129/batt), GPL-2) and
   `../chargnr-refs/OpenDente` ([killerk3emstar/OpenDente](https://github.com/killerk3emstar/OpenDente), GPL-3)
   are *references* only. Read them to learn how things work, then write chargnr's
   own code, names, comments and structure. Never paste their files, functions,
   comments, strings or assets. Hardware facts (SMC key names, byte values, write
   order, IOKit API names) are fine to reuse.
4. Keep it small, fast and native: Swift + AppKit/SwiftUI + IOKit, no third-party
   dependencies unless the user agrees.
5. Never write an SMC key without checking it exists and that the byte count
   matches its size. Every write is read back. Tests use `FakeSMC`, never real hardware.
   Only `Actuator` writes charging keys. Anything that changes charging must check
   its preconditions first, so a failed command changes nothing.

## Layout

```
Package.swift            SwiftPM: core library, CLI, helper
Sources/ChargnrCore      SMC/, Hardware/ (detection, readings, macOS limit), Control/ (policy,
                         actuator, controller), Helper/ (XPC protocol, caller policy, installer)
Sources/chargnr          CLI
Sources/chargnr-helper   root daemon: charge loop, sleep hooks, XPC server
App/                     menu bar app: AppModel (state), PopoverView, SettingsView,
                         Notifier, HelperInstaller (SMAppService or admin-password CLI install)
Tests/ChargnrCoreTests   swift-testing tests
docs/hardware.md         SMC keys and firmware findings; update it when hardware facts change
docs/helper.md           helper design: methods, safety rules, caller policy, install
```

## Build and run

```sh
swift build                 # core, CLI, helper
swift test                  # unit tests (fake hardware only)
make app                    # xcodegen + xcodebuild the menu bar app (scheme chargnr-app)
open build/Build/Products/Debug/chargnr.app
# Render the popover and settings with live data, without touching the screen:
build/Build/Products/Debug/chargnr.app/Contents/MacOS/chargnr --snapshot /tmp/p.png [--dark]
```

- Requires Xcode 16+ and XcodeGen (`brew install xcodegen`). `chargnr.xcodeproj`
  is generated, not committed.
- The Xcode scheme is `chargnr-app`: the Swift package also has a `chargnr`
  scheme (the CLI), and `-scheme chargnr` silently builds that instead.
- The app bundle carries `Contents/MacOS/chargnr-helper` and `chargnr-cli`.
- Signed ad hoc for now (`CODE_SIGN_IDENTITY = -`). Ad-hoc builds install the
  helper through the embedded CLI with an administrator password prompt;
  team-signed builds use SMAppService.

## Roadmap

0. Repo, build, CI, fake hardware ← done
1. Real AppleSMC transport, key-set detection (legacy / Tahoe / macOS 27 firmware), `chargnr status` ← done (see docs/hardware.md: firmware 20457.1 has no charge keys)
2. Root helper: SMAppService, XPC with signing check, verified writes, crash recovery, sleep hooks ← done (needs hardware test)
3. Charging logic: limit, sailing, heat, top up, discharge, adapter, MagSafe LED ← done (needs hardware test)
4. Menu bar UI, notifications, login item ← done
5. CLI parity, calibration + schedule, history, Shortcuts
6. Signing, notarization, DMG, Homebrew cask
