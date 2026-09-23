import ChargnrCore
import Foundation

let profiles = FakeSMC.Profile.allCases.map(\.rawValue).joined(separator: ", ")
let usage = """
    usage: chargnr <command> [options]

    commands:
      status [--json]    battery, charging state and what this Mac supports
      limit PERCENT      stop charging at PERCENT (20–100) [--gap N, default 5]
      limit off          charge normally
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
            let limit = helper.config.isLimited ? "limit \(helper.config.limit)% (resume at \(helper.config.resumeBelow)%)" : "no limit"
            print("Helper".padding(toLength: 18, withPad: " ", startingAt: 0)
                  + "running \(helper.version), \(limit), method \(helper.method.rawValue)")
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
    guard options.fake == nil else { fail("limit only works on the real Mac") }
    let percent: Int
    if value == "off" { percent = 100 } else {
        guard let number = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "%"))),
              ChargeConfig.limitRange.contains(number) else { fail("limit must be 20–100 or off") }
        percent = number
    }
    let config = ChargeConfig(limit: percent, gap: options.gap ?? ChargeConfig().gap)
    let caps = Capabilities.detect(options.transport())
    let usesNative = (caps.charging == .gated || caps.charging == .unsupported) && NativeChargeLimit.read() != nil

    let needsHelper = ControlMethod.choose(for: config, caps: caps) != .none
    let client = HelperClient()

    // Check the helper first so a failure changes nothing.
    if needsHelper {
        do { _ = try await client.status() } catch { fail("\(error)", code: 69) }
    }
    // On gated firmware macOS enforces 80%+ itself. For lower limits it is
    // set to 80% as a floor, so charging stays capped while the Mac sleeps
    // and the helper cannot switch the adapter.
    if usesNative {
        guard getuid() != 0 else { fail("run limit without sudo: macOS's own limit belongs to your user") }
        do { try NativeChargeLimit.set(max(percent, NativeLimitRange.minimum)) } catch {
            fail("macOS refused the charge limit: \(error)", code: 70)
        }
    }
    do {
        try await client.setConfig(config)
    } catch {
        // Without the helper, 80%+ on gated firmware still works through macOS.
        if needsHelper { fail("\(error)", code: 69) }
    }
    switch (percent, needsHelper, usesNative) {
    case (100, _, _): print("Charging normally.")
    case (_, false, true): print("Limit \(percent)%, enforced by macOS (also during sleep).")
    case (_, true, true): print("Limit \(percent)%, held by the helper switching the adapter; macOS caps sleep charging at 80%.")
    default: print("Limit \(percent)%, resume below \(config.resumeBelow)%.")
    }
case "install":
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("chargnr-helper").path
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
