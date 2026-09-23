import ChargnrCore
import Foundation

let profiles = FakeSMC.Profile.allCases.map(\.rawValue).joined(separator: ", ")
let usage = """
    usage: chargnr <command> [options]

    commands:
      status [--json]    battery, charging state and what this Mac supports
      limit PERCENT      stop charging at PERCENT (20–100) [--gap N, default 5]
      limit off          charge normally
      sailing POINTS     at the limit, pause charging until the battery drops
                         POINTS below it (1–20, default 5); sailing off = 1
      heat CELSIUS       pause charging while the battery is this hot (30–45); heat off
      topup [cancel]     charge to 100% once, then return to the limit
      discharge PERCENT  run from battery while plugged in down to PERCENT (10–99)
      discharge cancel   stop discharging
      led MODE           MagSafe LED: status (green at the limit), off, or system
      calibrate [--to N] [--hold MIN]
                         discharge to N% (15), charge to 100%, hold MIN (60), resume limit
      calibrate cancel | skip
      schedule DAYS [--hour H]  calibrate every DAYS (7–90) from hour H (3); schedule off
      history [--hours N] [--json]
                         battery history recorded by the helper (default 24 h, up to 30 days)
      install            install the background helper (needs sudo)
      uninstall          remove the helper and restore normal charging (needs sudo)
      keys [--all|KEY…]  raw values of the SMC keys chargnr uses (--all: every key)
      adapter on         switch wall power back on (needs sudo)
      adapter off --for SECONDS
                         run from battery while plugged in, then switch power
                         back on by itself (needs sudo, 1–3600 s)
      version            print the version
      help               show this help

    options:
      --fake NAME        use a simulated Mac instead of the real one (\(profiles))
    """

let chargingKeys: [SMCKey] = [
    SMCKeys.chargeInhibitB, SMCKeys.chargeInhibitC, SMCKeys.chargeInhibitTahoe,
    SMCKeys.firmwareLimitActive, SMCKeys.firmwareLimitUpper, SMCKeys.firmwareLimitLower,
] + SMCKeys.adapterKeys + [
    SMCKeys.magSafeLED, SMCKeys.batteryPercent, SMCKeys.acPower, SMCKeys.batteryTemperature,
]

func fail(_ message: String, code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data("chargnr: \(message)\n".utf8))
    exit(code)
}

struct Options {
    var json = false
    var all = false
    var fake: FakeSMC.Profile?
    var keys: [SMCKey] = []
    var seconds: Int?
    var gap: Int?
    var to: Int?
    var hold: Int?
    var hour: Int?
    var hours: Int?

    init(_ args: ArraySlice<String>) {
        var args = args
        while let arg = args.popFirst() {
            switch arg {
            case "--json": json = true
            case "--all": all = true
            case "--gap":
                guard let value = args.popFirst().flatMap(Int.init), ChargeConfig.gapRange.contains(value) else {
                    fail("--gap needs a number from \(ChargeConfig.gapRange.lowerBound) to \(ChargeConfig.gapRange.upperBound)")
                }
                gap = value
            case "--to", "--hold", "--hour", "--hours":
                guard let value = args.popFirst().flatMap(Int.init) else { fail("\(arg) needs a number") }
                switch arg {
                case "--to": to = value
                case "--hold": hold = value
                case "--hour": hour = value
                default: hours = value
                }
            case "--for":
                guard let value = args.popFirst().flatMap(Int.init), (1...3600).contains(value) else {
                    fail("--for needs a number of seconds from 1 to 3600")
                }
                seconds = value
            case "--fake":
                guard let name = args.popFirst(), let profile = FakeSMC.Profile(rawValue: name) else {
                    fail("--fake needs one of: \(profiles)")
                }
                fake = profile
            default:
                guard !arg.hasPrefix("-"), let key = SMCKey(string: arg) else { fail("unknown option '\(arg)'") }
                keys.append(key)
            }
        }
    }

    func transport() -> any SMCTransport {
        if let fake { return FakeSMC(profile: fake) }
        do { return try AppleSMC() } catch { fail("cannot open the SMC (\(error))", code: 69) }
    }
}

/// Applies a config change through the helper (and macOS's limit where used).
func updateConfig(_ options: Options, requireHelper: Bool = false,
                  _ change: @escaping @Sendable (inout ChargeConfig) -> Void) async -> ConfigUpdater.Outcome {
    guard options.fake == nil else { fail("this command only works on the real Mac") }
    let updater = ConfigUpdater(caps: Capabilities.detect(options.transport()))
    do { return try await updater.update(requireHelper: requireHelper, change) } catch { fail("\(error)", code: 69) }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func printStatus(_ r: StatusReport) {
    func row(_ label: String, _ value: String?) {
        guard let value else { return }
        print(label.padding(toLength: 18, withPad: " ", startingAt: 0) + value)
    }
    func onOff(_ value: Bool?, _ yes: String, _ no: String) -> String? { value.map { $0 ? yes : no } }

    row("Mac", [r.model, r.firmware.map { "firmware \($0)" }, "macOS \(r.macOS)"].compactMap { $0 }.joined(separator: ", "))
    row("Control", r.capabilities.charging.summary)

    if let b = r.battery {
        let state = b.isCharging ? "charging" : b.externalConnected ? "plugged in, not charging" : "on battery"
        row("Battery", "\(b.percent)%, \(state)")
        row("Health", b.healthPercent.map { "\($0)% (\(b.fullChargeCapacity ?? 0) of \(b.designCapacity ?? 0) mAh), \(b.cycleCount) cycles" })
        row("Power", String(format: "battery %+.1f W", Double(b.batteryPowerMW) / 1000)
            + (b.systemLoadMW.map { String(format: ", Mac using %.1f W", Double($0) / 1000) } ?? ""))
        row("Adapter", b.adapterName.map { name in b.adapterWatts.map { "\(name) (\($0) W)" } ?? name })
        row("Time left", b.minutesRemaining.map { "\($0 / 60)h \($0 % 60)m" })
    } else {
        row("Battery", r.charge.percent.map { "\($0)%" })
        row("Plugged in", onOff(r.charge.pluggedIn, "yes", "no"))
    }

    row("Temperature", r.charge.temperatureC.map { String(format: "%.1f °C", $0) })
    if let limit = r.charge.firmwareLimit {
        row("Firmware limit", limit.active ? "on, \(limit.lower)–\(limit.upper)%" : "off")
    }
    row("macOS limit", r.nativeLimit.map { $0.enabled ? "on, \($0.limit)%" : "off (choices: \($0.available.map(String.init).joined(separator: ", ")))" })
    row("Charging", onOff(r.charge.chargingInhibited, "inhibited", "allowed"))
    row("Adapter power", onOff(r.charge.adapterDisabled, "off (running on battery)", "on"))
    row("MagSafe LED", r.charge.magSafeLED.map { ["system", "off", "?", "green", "orange"][safe: Int($0)] ?? "0x\(String($0, radix: 16))" })

    switch r.capabilities.charging {
    case .gated:
        print("""

            Apple locked the charge-control keys on this firmware. chargnr will limit
            charging through macOS's own limit (80–100%) or by switching the adapter off.
            """)
    case .unsupported:
        print("""

            This firmware exposes no charge-control keys, so chargnr cannot stop
            charging directly. Use the built-in limit in System Settings › Battery.
            """)
    default:
        break
    }
    if r.capabilities.charging == .gated || r.capabilities.charging == .unsupported {
        if r.capabilities.canDisableAdapter { print("The adapter switch still works (force discharge).") }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

var args = CommandLine.arguments.dropFirst()

switch args.popFirst() {
case "status":
    let options = Options(args)
    let smc = options.transport()
    let real = options.fake == nil
    if real && Installer.isInstalled {
        // Catch up macOS's limit if the helper ended a top up while we were away.
        await ConfigUpdater(caps: Capabilities.detect(smc)).syncNativeLimit()
    }
    let report = StatusReport.collect(smc: smc, battery: real ? BatteryInfo.current() : nil,
                                      nativeLimit: real ? NativeChargeLimit.read() : nil)
    let helper = real && Installer.isInstalled ? try? await HelperClient().status() : nil
    if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    } else {
        printStatus(report)
        print("")
        if let helper {
            let limit = helper.config.isLimited
                ? "limit \(helper.config.limit)%, sailing \(helper.config.gap) (resume below \(helper.config.resumeBelow)%)" : "no limit"
            print("Helper".padding(toLength: 18, withPad: " ", startingAt: 0)
                  + "running \(helper.version), \(limit), method \(helper.method.rawValue)")
            if helper.config.led != .system {
                print("LED mode".padding(toLength: 18, withPad: " ", startingAt: 0) + helper.config.led.rawValue)
            }
            if let until = helper.topUpUntil {
                print("Top up".padding(toLength: 18, withPad: " ", startingAt: 0)
                      + "charging to 100% (ends when full, on unplug, or at \(until.formatted(date: .omitted, time: .shortened)))")
            }
            if let run = helper.calibration {
                let step = switch run.step {
                case .discharge: "discharging to \(run.dischargeTo)%"
                case .charge: "charging to 100%"
                case .hold: "holding at 100% for \(run.holdMinutes) min"
                }
                print("Calibration".padding(toLength: 18, withPad: " ", startingAt: 0) + "step: \(step)")
            }
            if let next = helper.nextCalibration {
                print("Next calibration".padding(toLength: 18, withPad: " ", startingAt: 0)
                      + next.formatted(date: .abbreviated, time: .shortened))
            }
            if let target = helper.dischargeTo {
                print("Discharge".padding(toLength: 18, withPad: " ", startingAt: 0) + "running on battery down to \(target)%")
            }
            if let t = helper.temperatureC, let heat = helper.config.heatLimit {
                print("Heat protection".padding(toLength: 18, withPad: " ", startingAt: 0)
                      + String(format: "%@ (battery %.1f °C, limit %d °C)", helper.heatHold == true ? "pausing charging" : "on", t, heat))
            }
            if helper.version != Chargnr.version {
                print("Helper update".padding(toLength: 18, withPad: " ", startingAt: 0)
                      + "helper is \(helper.version), chargnr is \(Chargnr.version): run sudo chargnr install")
            }
            if let error = helper.lastError { print("Helper error".padding(toLength: 18, withPad: " ", startingAt: 0) + error) }
        } else if real {
            print("Helper".padding(toLength: 18, withPad: " ", startingAt: 0)
                  + (Installer.isInstalled ? "installed but not answering" : "not installed (sudo chargnr install)"))
        }
    }
case "keys":
    let options = Options(args)
    let smc = options.transport()
    var keys = options.keys.isEmpty ? chargingKeys : options.keys
    if !options.keys.isEmpty {
        // Explicit keys: show errors instead of skipping, for firmware research.
        for key in keys {
            do {
                guard let info = try smc.keyInfo(key) else { print("\(key)  missing"); continue }
                let value = info.size == 0 ? "(zero-size placeholder)" : (try? smc.read(key)).map(hex) ?? "(unreadable)"
                print("\(key)  \(info.type)  \(info.size)B  \(value)")
            } catch {
                print("\(key)  error: \(error)")
            }
        }
        exit(0)
    }
    if options.all {
        guard let real = smc as? AppleSMC else { fail("--all needs the real SMC") }
        do { keys = try real.allKeys() } catch { fail("cannot list keys (\(error))", code: 69) }
    }
    for key in keys {
        guard let info = try? smc.keyInfo(key) else { continue }
        let value = (try? smc.read(key)).map(hex) ?? "(unreadable)"
        print("\(key)  \(info.type)  \(info.size)B  \(value)")
    }
case "limit":
    guard let value = args.popFirst() else { fail("usage: chargnr limit PERCENT | off") }
    let options = Options(args)
    let percent: Int
    if value == "off" { percent = 100 } else {
        guard let number = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "%"))),
              ChargeConfig.limitRange.contains(number) else { fail("limit must be 20–100 or off") }
        percent = number
    }
    let gap = options.gap
    let outcome = await updateConfig(options) { config in
        config.limit = percent
        if let gap { config.gap = gap }
    }
    let c = outcome.config
    switch (c.limit, outcome.method, outcome.usesNativeLimit) {
    case (100, _, _): print("Charging normally.")
    case (_, .none, true): print("Limit \(c.limit)%, enforced by macOS (also during sleep).")
    case (_, .adapter, true): print("Limit \(c.limit)%: the helper switches the adapter off at \(c.limit)% and back on below \(c.resumeBelow)%. macOS caps sleep charging at 80%.")
    default: print("Limit \(c.limit)%, charging resumes below \(c.resumeBelow)%.")
    }
case "sailing":
    guard let value = args.popFirst() else { fail("usage: chargnr sailing POINTS | off") }
    let options = Options(args)
    let gap: Int
    if value == "off" { gap = ChargeConfig.noSailingGap } else {
        guard let number = Int(value), ChargeConfig.gapRange.contains(number) else {
            fail("sailing must be \(ChargeConfig.gapRange.lowerBound)–\(ChargeConfig.gapRange.upperBound) points or off")
        }
        gap = number
    }
    let outcome = await updateConfig(options, requireHelper: true) { $0.gap = gap }
    let c = outcome.config
    if !c.isLimited {
        print("Sailing \(c.gap) points saved; it applies once you set a limit below 100%.")
    } else if outcome.method == .none && outcome.usesNativeLimit {
        print("Sailing \(c.gap) points saved. macOS's own limit decides when to resume at \(c.limit)%; sailing applies to limits below 80%.")
    } else if gap == ChargeConfig.noSailingGap {
        print("Sailing off: charging resumes as soon as the battery drops below \(c.limit)%.")
    } else {
        print("Sailing \(c.gap) points: at \(c.limit)% charging pauses until the battery drops below \(c.resumeBelow)%.")
    }
case "heat":
    guard let value = args.popFirst() else { fail("usage: chargnr heat CELSIUS | off") }
    let options = Options(args)
    let limit: Int?
    if value == "off" { limit = nil } else {
        guard let number = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "°Cc"))),
              ChargeConfig.heatLimitRange.contains(number) else {
            fail("heat must be \(ChargeConfig.heatLimitRange.lowerBound)–\(ChargeConfig.heatLimitRange.upperBound) °C or off")
        }
        limit = number
    }
    let outcome = await updateConfig(options, requireHelper: limit != nil) { $0.heatLimit = limit }
    if let limit = outcome.config.heatLimit {
        let how = Capabilities.detect(options.transport()).canInhibit ? "pauses charging" : "runs the Mac from battery"
        print("Heat protection on: at \(limit) °C chargnr \(how) until the battery cools to \(limit - Int(ChargeConfig.heatHysteresis)) °C (at least \(Int(ChargeConfig.heatCooldown / 60)) min).")
    } else {
        print("Heat protection off.")
    }
case "topup":
    let cancel = args.first == "cancel"
    if cancel { args.removeFirst() }
    let options = Options(args)
    let until = Date().addingTimeInterval(ChargeConfig.topUpMaximum)
    let outcome = await updateConfig(options, requireHelper: !cancel) {
        $0.topUpUntil = cancel ? nil : until
        if !cancel {
            $0.dischargeTo = nil
            $0.calibration = nil
        }
    }
    if cancel {
        print("Top up cancelled; back to the \(outcome.config.limit)% limit.")
    } else if !outcome.config.isLimited {
        print("No limit is set, so the battery already charges to 100%.")
    } else if let percent = BatteryInfo.current()?.percent, percent >= 100 {
        print("The battery is already full; nothing to top up.")
    } else {
        print("Charging to 100% once. The \(outcome.config.limit)% limit comes back when the battery is full, when you unplug, or after 12 hours.")
    }
case "discharge":
    guard let value = args.popFirst() else { fail("usage: chargnr discharge PERCENT | cancel") }
    let options = Options(args)
    let target: Int?
    if value == "cancel" { target = nil } else {
        guard let number = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "%"))),
              ChargeConfig.dischargeRange.contains(number) else {
            fail("discharge target must be \(ChargeConfig.dischargeRange.lowerBound)–\(ChargeConfig.dischargeRange.upperBound)% or cancel")
        }
        target = number
    }
    if target != nil, !Capabilities.detect(options.transport()).canDisableAdapter {
        fail("this Mac has no adapter switch, so it cannot discharge while plugged in")
    }
    let outcome = await updateConfig(options, requireHelper: target != nil) {
        $0.dischargeTo = target
        if target != nil {
            $0.topUpUntil = nil
            $0.calibration = nil
        }
    }
    if let target = outcome.config.dischargeTo {
        print("Discharging to \(target)% while plugged in. The Mac stays awake until then; sleep pauses it.")
    } else {
        print("Discharge stopped.")
    }
case "led":
    guard let value = args.popFirst(), let mode = ChargeConfig.LEDMode(rawValue: value) else {
        fail("usage: chargnr led status | off | system")
    }
    let options = Options(args)
    guard mode == .system || Capabilities.detect(options.transport()).magSafeLED else {
        fail("this Mac has no MagSafe LED chargnr can control")
    }
    _ = await updateConfig(options, requireHelper: mode != .system) { $0.led = mode }
    switch mode {
    case .status: print("MagSafe LED: orange while charging, green when the limit holds or the battery is full.")
    case .off: print("MagSafe LED off while plugged in.")
    case .system: print("MagSafe LED back to macOS.")
    }
case "calibrate":
    let action = args.first.map { ["start", "cancel", "skip"].contains($0) ? args.removeFirst() : "start" } ?? "start"
    let options = Options(args)
    let caps = Capabilities.detect(options.transport())
    switch action {
    case "start":
        guard caps.canDisableAdapter else { fail("calibration needs to discharge while plugged in, which this Mac cannot do") }
        let run = Calibration(dischargeTo: options.to ?? Calibration.defaultDischargeTo,
                              holdMinutes: options.hold ?? Calibration.defaultHoldMinutes, startedAt: Date())
        _ = await updateConfig(options, requireHelper: true) {
            $0.calibration = run
            $0.topUpUntil = nil
            $0.dischargeTo = nil
        }
        print("""
            Calibration started:
              1. discharge to \(run.dischargeTo)% (running on battery; the Mac stays awake)
              2. charge to 100%
              3. hold at 100% for \(run.holdMinutes) min
              4. back to your limit
            Keep the charger connected. Cancel with: chargnr calibrate cancel
            """)
    case "cancel":
        _ = await updateConfig(options, requireHelper: true) { $0.calibration = nil }
        print("Calibration cancelled.")
    default:
        _ = await updateConfig(options, requireHelper: true) { $0.lastCalibration = Date() }
        print("Next scheduled calibration skipped; the schedule counts from now.")
    }
case "schedule":
    guard let value = args.popFirst() else { fail("usage: chargnr schedule DAYS [--hour H] | off") }
    let options = Options(args)
    let schedule: CalibrationSchedule?
    if value == "off" { schedule = nil } else {
        guard let days = Int(value), CalibrationSchedule.everyDaysRange.contains(days) else {
            fail("schedule must be \(CalibrationSchedule.everyDaysRange.lowerBound)–\(CalibrationSchedule.everyDaysRange.upperBound) days or off")
        }
        guard (0...23).contains(options.hour ?? 3) else { fail("--hour must be 0–23") }
        schedule = CalibrationSchedule(everyDays: days, hour: options.hour ?? 3)
    }
    let outcome = await updateConfig(options, requireHelper: schedule != nil) {
        $0.schedule = schedule
        if schedule != nil, $0.lastCalibration == nil { $0.lastCalibration = Date() }
    }
    if let schedule, let last = outcome.config.lastCalibration {
        let next = schedule.nextRun(after: last)
        print("Calibration every \(schedule.everyDays) days. Next: \(next.formatted(date: .abbreviated, time: .shortened)), once the charger is connected.")
    } else {
        print("Calibration schedule off.")
    }
case "history":
    let options = Options(args)
    let hours = min(max(options.hours ?? 24, 1), 24 * 30)
    let since = Date().addingTimeInterval(-Double(hours) * 3600)
    let samples: [HistorySample]
    do { samples = try await HelperClient().history(since: since) } catch {
        if case .refused = error {
            fail("the installed helper is older than this chargnr and has no history; update it with: sudo chargnr install", code: 69)
        }
        fail("\(error)", code: 69)
    }
    if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(samples), as: UTF8.self))
        exit(0)
    }
    guard let summary = HistorySummary(samples) else {
        print("No history yet for the last \(hours) h. The helper records as the battery changes.")
        exit(0)
    }
    func pct(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
    print("Last \(hours) h: battery \(summary.minPercent)–\(summary.maxPercent)%, plugged in \(pct(summary.pluggedShare)) of the time, "
          + "at 95%+ \(pct(summary.nearFullShare)), held by chargnr \(pct(summary.heldShare))"
          + (summary.maxTemperatureC.map { String(format: ", hottest %.1f °C", $0) } ?? "") + ".")
    print("")
    // One row per hour: the reading closest to the start of that hour.
    let formatter = DateFormatter()
    formatter.dateFormat = hours > 48 ? "MMM d HH:mm" : "HH:mm"
    var bucket = Calendar.current.dateInterval(of: .hour, for: since)?.start ?? since
    var index = 0
    while bucket <= Date() {
        while index + 1 < samples.count, samples[index + 1].time <= bucket { index += 1 }
        let s = samples[index]
        if s.time <= bucket.addingTimeInterval(3600) {
            let bar = String(repeating: "█", count: s.percent / 5)
            let state = s.held ? "held" : s.charging ? "charging" : s.pluggedIn ? "plugged" : "battery"
            print("\(formatter.string(from: bucket))  \(String(format: "%3d", s.percent))%  \(bar.padding(toLength: 20, withPad: " ", startingAt: 0))  \(state)")
        }
        bucket = bucket.addingTimeInterval(hours > 48 ? 6 * 3600 : 3600)
    }
case "install":
    // Next to the CLI: .build/release, Homebrew, or chargnr.app/Contents/MacOS.
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let helper = here.appendingPathComponent("chargnr-helper").path
    do { try Installer.install(helper: helper) } catch { fail("\(error)", code: 70) }
    print("Helper installed and running. Set a limit with: chargnr limit 80")
case "uninstall":
    do { try Installer.uninstall() } catch { fail("\(error)", code: 70) }
    print("Helper removed; charging is back to normal.")
case "adapter":
    let action = args.popFirst()
    let options = Options(args)
    guard options.fake == nil else { fail("adapter only works on the real Mac") }
    let smc = options.transport()
    let caps = Capabilities.detect(smc)

    @Sendable func switchAdapter(_ on: Bool) {
        do {
            try Adapter.set(enabled: on, smc: smc, caps: caps)
        } catch .needsRoot {
            fail("switching the adapter needs root: run it with sudo", code: 77)
        } catch {
            fail("could not switch the adapter \(on ? "on" : "off"): \(error)", code: 70)
        }
    }

    switch action {
    case "on":
        switchAdapter(true)
        print("Adapter on.")
    case "off":
        guard let seconds = options.seconds else {
            fail("adapter off needs --for SECONDS, so power always comes back")
        }
        // Restore power on Ctrl-C or kill, not only when the timer ends.
        let signals = [SIGINT, SIGTERM, SIGHUP]
        for sig in signals { signal(sig, SIG_IGN) }
        let sources = signals.map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                switchAdapter(true)
                print("\nInterrupted. Adapter on.")
                exit(130)
            }
            source.resume()
            return source
        }

        switchAdapter(false)
        print("Adapter off for \(seconds) s (\(caps.adapterKey?.description ?? "?")). Ctrl-C switches it back on.")
        for elapsed in 1...seconds {
            sleep(1)
            let b = BatteryInfo.current()
            let state = ChargeState.read(smc, caps)
            print(String(format: "%3d s  battery %@%%  %+.1f W  adapter %@", elapsed,
                         b.map { String($0.percent) } ?? "?",
                         Double(b?.batteryPowerMW ?? 0) / 1000,
                         state.adapterDisabled == true ? "off" : "on"))
        }
        switchAdapter(true)
        withExtendedLifetime(sources) { print("Adapter on.") }
    default:
        fail("usage: chargnr adapter on | off --for SECONDS")
    }
case "version", "--version", "-v":
    print("chargnr \(Chargnr.version)")
case "help", "--help", "-h", nil:
    print(usage)
case let other?:
    fail("unknown command '\(other)'\n\(usage)")
}
