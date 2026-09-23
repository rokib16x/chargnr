# The helper

`chargnr-helper` is a root LaunchDaemon. It owns every SMC write, runs the
charge loop (so limits hold with the app closed), and serves the app and CLI
over XPC as `com.rokib16x.chargnr.helper`.

## How a limit is enforced

`ControlMethod.choose` picks one of three ways, per Mac and per limit:

| Firmware | Limit | Method | Who enforces it |
|---|---|---|---|
| Legacy / Tahoe keys | any | `inhibit` (CH0B+CH0C or CHTE) | helper |
| Early macOS 27 (`bfF0` usable) | any | `inhibit` if CHTE exists, else firmware | helper |
| Gated (20457.1+) | 80–100% | `none`: macOS's own limit via PowerUI, set by the app/CLI as the user | macOS, also during sleep |
| Gated (20457.1+) | 20–79% | `adapter` (CHIE) + macOS limit at 80% as a sleep floor | helper while awake, macOS while asleep |

## Features and precedence

The policy combines these, strongest first:

1. **Force discharge** (`discharge PERCENT`): adapter off until the battery is
   down to PERCENT, then clears. Holds a prevent-idle-sleep assertion; if the
   Mac sleeps anyway the adapter is restored and it resumes on wake.
2. **Heat protection** (`heat CELSIUS`): at the limit temperature, stop
   charging (inhibit keys) or cut the adapter (gated firmware). Resumes only
   2 °C cooler and at least 5 minutes later. Only ever switches things off.
3. **Top up** (`topup`): ignore the limit until full, unplugged, or 12 hours.
   On gated firmware macOS's limit is lifted to 100% and put back afterwards
   (by the helper if root may, otherwise by the next `chargnr` command or the app).
4. **Limit and sailing** (`limit`, `sailing`): stop at the limit, resume
   `gap` points below it. The adapter method keeps a band of at least 3.

**Safety floors.** At or below 10% nothing cuts the adapter, whatever the
settings. Heat protection that can only cut the adapter (gated firmware) stops
at 40%: a hot battery may not cool while the Mac runs from it, so it could
otherwise drain flat. Found in hardware testing with heat at 30 °C and a
battery idling at 35 °C.

**MagSafe LED** (`led status|off|system`) is set after the switches, only when
its value changes. `status` shows orange while the battery takes charge
(IOKit `IsCharging`) and green otherwise. The LED is handed back to macOS
(`ACLC = 0`) when leaving an LED mode, on restore, and after a crash. If a Mac
refuses LED writes, LED control switches off for the session and charging
control carries on.

Top up and discharge cancel each other. Settings that need the helper fail up
front when it is not running.

**Calibration** (`calibrate`, `schedule`): discharge to 15% (a discharge
with the keep-awake assertion), charge to 100% (macOS's limit lifted by the
helper), hold for 60 minutes, then back to the limit. Abandoned after 24 hours.
A schedule starts a run every N days from a set hour once plugged in.

**History**: the helper appends a CSV sample to
`/Library/Application Support/chargnr/history.csv` on every change of level,
charger, charging or held state, and every 10 minutes otherwise, and trims it
to 30 days. `history(since:)` over XPC serves the CLI and the app's chart.

Confirmed on firmware 20457.1.29 with helper 0.2.0: calibration's discharge
step cuts the adapter (input 0.1 W) with macOS's limit left at 85%, `stop`
restores it (19.9 W), and the helper holds `PreventUserIdleSystemSleep`
("chargnr force discharge") only while discharging.

## Safety rules

- **Only `Actuator` writes charging keys.** It skips writes already in place,
  reads every write back and retries three times.
- **Crash recovery.** Before any switch leaves normal, the intended state is
  saved to `/Library/Application Support/chargnr/switched.json`. On start the
  helper restores normal charging first, then re-applies the policy.
- **Exit.** SIGTERM (uninstall, shutdown, restart), SIGINT and SIGHUP restore
  normal charging before exiting. launchd `KeepAlive` restarts a crashed helper.
- **Sleep.** Never vetoes sleep. On `SystemWillSleep`: adapter method switches
  the adapter back on (a cut adapter during sleep could drain the battery flat);
  inhibit method stops charging so the Mac cannot creep past the limit.
  On wake it re-checks immediately.
- **Wakeups.** Checks every 3 min far from the limit, 1 min within 10 points,
  20 s within 3 points or while a switch is changed, 5 min with no limit.
  Plug/unplug and percentage changes trigger an extra check. Timers have leeway
  so macOS can batch them.

## Who may connect

`CallerPolicy`, decided from the helper's own signature:

- **Team-signed** (release): only `com.rokib16x.chargnr` and
  `com.rokib16x.chargnr.cli` signed by the same Team ID, enforced per message by
  `setCodeSigningRequirement` on the audit token.
- **Not team-signed** (built from source, Homebrew formula): root or the user
  who owns `/dev/console`. The interface only accepts a validated
  `ChargeConfig`, never raw keys.

## Installing

- **App:** "Install Helper…" registers `Contents/Library/LaunchDaemons/com.rokib16x.chargnr.helper.plist`
  with `SMAppService.daemon`. macOS asks for approval in Login Items.
- **CLI:** `sudo chargnr install` copies the helper to
  `/Library/PrivilegedHelperTools/com.rokib16x.chargnr.helper` (root-owned, 0755),
  writes `/Library/LaunchDaemons/com.rokib16x.chargnr.helper.plist` and
  bootstraps it. `sudo chargnr uninstall` reverses it.

Use one or the other; the app refuses to register while a CLI install exists.

## Logs

```sh
log stream --predicate 'subsystem == "com.rokib16x.chargnr.helper"'
```
