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
