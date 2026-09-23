import ChargnrCore
import Foundation

let profiles = FakeSMC.Profile.allCases.map(\.rawValue).joined(separator: ", ")
let usage = """
    usage: chargnr <command> [options]

    commands:
      status [--json]    battery, charging state and what this Mac supports
      keys [--all]       raw values of the SMC keys chargnr uses (--all: every key)
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

    init(_ args: ArraySlice<String>) {
        var args = args
        while let arg = args.popFirst() {
            switch arg {
            case "--json": json = true
            case "--all": all = true
            case "--fake":
                guard let name = args.popFirst(), let profile = FakeSMC.Profile(rawValue: name) else {
                    fail("--fake needs one of: \(profiles)")
                }
                fake = profile
            default: fail("unknown option '\(arg)'")
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
    row("Charging", onOff(r.charge.chargingInhibited, "inhibited", "allowed"))
    row("Adapter power", onOff(r.charge.adapterDisabled, "off (running on battery)", "on"))
    row("MagSafe LED", r.charge.magSafeLED.map { ["system", "off", "?", "green", "orange"][safe: Int($0)] ?? "0x\(String($0, radix: 16))" })

    if r.capabilities.charging == .unsupported {
        print("""

            This firmware exposes no charge-control keys, so chargnr cannot stop
            charging directly yet. Use the built-in limit in System Settings › Battery.
            """)
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
    let report = StatusReport.collect(smc: smc, battery: options.fake == nil ? BatteryInfo.current() : nil)
    if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    } else {
        printStatus(report)
    }
case "keys":
    let options = Options(args)
    let smc = options.transport()
    var keys = chargingKeys
    if options.all {
        guard let real = smc as? AppleSMC else { fail("--all needs the real SMC") }
        do { keys = try real.allKeys() } catch { fail("cannot list keys (\(error))", code: 69) }
    }
    for key in keys {
        guard let info = try? smc.keyInfo(key) else { continue }
        let value = (try? smc.read(key)).map(hex) ?? "(unreadable)"
        print("\(key)  \(info.type)  \(info.size)B  \(value)")
    }
case "version", "--version", "-v":
    print("chargnr \(Chargnr.version)")
case "help", "--help", "-h", nil:
    print(usage)
case let other?:
    fail("unknown command '\(other)'\n\(usage)")
}
