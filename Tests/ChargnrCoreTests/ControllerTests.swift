@testable import ChargnrCore
import Foundation
import os
import Testing

/// A battery the tests can move.
final class FakeBattery: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: BatteryReading(percent: 50, pluggedIn: true))
    var reading: BatteryReading {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

struct Rig {
    let smc: FakeSMC
    let battery = FakeBattery()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let controller: Controller
    var marker: JSONFile<ChargeOutput> { JSONFile(dir.appendingPathComponent("switched.json")) }

    init(_ profile: FakeSMC.Profile, config: ChargeConfig? = nil) throws {
        smc = FakeSMC(profile: profile)
        let configFile = JSONFile<ChargeConfig>(dir.appendingPathComponent("config.json"))
        if let config { try configFile.save(config) }
        let battery = self.battery
        controller = Controller(actuator: Actuator(smc: smc, caps: Capabilities.detect(smc)),
                                configFile: configFile,
                                marker: JSONFile(dir.appendingPathComponent("switched.json")),
                                log: .quiet, readBattery: { battery.reading })
    }

    func set(_ percent: Int, plugged: Bool = true) {
        battery.reading = BatteryReading(percent: percent, pluggedIn: plugged)
        controller.tick()
    }
}

@Suite struct ControllerTests {
    @Test func holdsLimitWithInhibit() throws {
        let rig = try Rig(.tahoe, config: ChargeConfig(limit: 80, gap: 5))
        rig.controller.start()
        rig.set(79)
        #expect(try rig.smc.read("CHTE") == [0, 0, 0, 0])
        rig.set(80)
        #expect(try rig.smc.read("CHTE") == [1, 0, 0, 0])
        #expect(rig.marker.load() != nil, "a changed switch is recorded for crash recovery")
        rig.set(76)
        #expect(try rig.smc.read("CHTE") == [1, 0, 0, 0], "inside the band")
        rig.set(75)
        #expect(try rig.smc.read("CHTE") == [0, 0, 0, 0])
        #expect(rig.marker.load() == nil)
    }

    @Test func holdsSub80LimitWithAdapterOnGatedFirmware() throws {
        let rig = try Rig(.gated, config: ChargeConfig(limit: 60, gap: 5))
        rig.controller.start()
        #expect(rig.controller.method == .adapter)
        rig.set(61)
        #expect(try rig.smc.read("CHIE") == [0x08])
        rig.set(58, plugged: false) // adapter off reads as unplugged
        #expect(try rig.smc.read("CHIE") == [0x08])
        rig.set(55, plugged: false)
        #expect(try rig.smc.read("CHIE") == [0x00])
    }

    @Test func leaves80PlusToMacOSOnGatedFirmware() throws {
        let rig = try Rig(.gated, config: ChargeConfig(limit: 85))
        rig.controller.start()
        rig.set(95)
        #expect(rig.smc.writes.isEmpty)
        #expect(rig.controller.status().method == .none)
    }

    @Test func restoresOnStartAfterCrash() throws {
        let rig = try Rig(.gated, config: ChargeConfig(limit: 60))
        rig.smc.set("CHIE", type: "hex_", [0x08]) // left off by a dead run
        try rig.marker.save(ChargeOutput(chargingAllowed: true, adapterOn: false))
        rig.battery.reading = BatteryReading(percent: 40, pluggedIn: true)
        rig.controller.start()
        #expect(try rig.smc.read("CHIE") == [0x00])
        #expect(rig.marker.load() == nil)
    }

    @Test func adapterComesBackBeforeSleep() throws {
        let rig = try Rig(.gated, config: ChargeConfig(limit: 50))
        rig.controller.start()
        rig.set(70)
        #expect(try rig.smc.read("CHIE") == [0x08])
        rig.controller.willSleep()
        #expect(try rig.smc.read("CHIE") == [0x00])
        rig.battery.reading = BatteryReading(percent: 69, pluggedIn: true)
        rig.controller.didWake()
        #expect(try rig.smc.read("CHIE") == [0x08])
    }

    @Test func inhibitsBeforeSleep() throws {
        let rig = try Rig(.tahoe, config: ChargeConfig(limit: 80))
        rig.controller.start()
        rig.set(60)
        rig.controller.willSleep()
        #expect(try rig.smc.read("CHTE") == [1, 0, 0, 0])
    }

    @Test func configChangeAppliesAndPersists() throws {
        let rig = try Rig(.tahoe)
        rig.controller.start()
        rig.set(90)
        #expect(try rig.smc.read("CHTE") == [0, 0, 0, 0])
        try rig.controller.setConfig(ChargeConfig(limit: 80))
        #expect(try rig.smc.read("CHTE") == [1, 0, 0, 0])
        #expect(JSONFile<ChargeConfig>(rig.dir.appendingPathComponent("config.json")).load()?.limit == 80)
        try rig.controller.setConfig(ChargeConfig(limit: 100))
        #expect(try rig.smc.read("CHTE") == [0, 0, 0, 0])
    }

    @Test func checksLessOftenFarFromLimit() throws {
        let rig = try Rig(.tahoe, config: ChargeConfig(limit: 80))
        rig.controller.start()
        rig.set(40)
        #expect(rig.controller.interval == 180)
        rig.set(78)
        #expect(rig.controller.interval == 20)
        try rig.controller.setConfig(ChargeConfig(limit: 100))
        #expect(rig.controller.interval == 300)
    }

    @Test func reportsFailedWrites() throws {
        let rig = try Rig(.tahoe, config: ChargeConfig(limit: 80))
        rig.smc.rejectWrites(to: "CHTE")
        rig.controller.start()
        rig.set(85)
        #expect(rig.controller.status().lastError != nil)
    }
}

/// A clock the tests can move.
final class FakeClock: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
    var now: Date { state.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { state.withLock { $0 += seconds } }
}

@Suite struct HeatProtectionTests {
    func rig(_ profile: FakeSMC.Profile, config: ChargeConfig, clock: FakeClock) throws -> (FakeSMC, FakeBattery, Controller) {
        let smc = FakeSMC(profile: profile)
        let battery = FakeBattery()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = JSONFile<ChargeConfig>(dir.appendingPathComponent("config.json"))
        try file.save(config)
        let controller = Controller(actuator: Actuator(smc: smc, caps: Capabilities.detect(smc)),
                                    configFile: file, marker: JSONFile(dir.appendingPathComponent("m.json")),
                                    now: { clock.now }, log: .quiet, readBattery: { battery.reading })
        controller.start()
        return (smc, battery, controller)
    }

    @Test func pausesChargingWhenHotAndWaitsForCooldown() throws {
        let clock = FakeClock()
        let (smc, battery, controller) = try rig(.tahoe, config: ChargeConfig(heatLimit: 35), clock: clock)
        battery.reading = BatteryReading(percent: 50, pluggedIn: true, temperatureC: 34.9)
        controller.tick()
        #expect(try smc.read("CHTE") == [0, 0, 0, 0])

        battery.reading.temperatureC = 35.0
        controller.tick()
        #expect(try smc.read("CHTE") == [1, 0, 0, 0])
        #expect(controller.status().heatHold == true)

        battery.reading.temperatureC = 32.0 // cooled, but cooldown not over
        clock.advance(60)
        controller.tick()
        #expect(try smc.read("CHTE") == [1, 0, 0, 0])

        clock.advance(ChargeConfig.heatCooldown)
        controller.tick()
        #expect(try smc.read("CHTE") == [0, 0, 0, 0])
        #expect(controller.status().heatHold == false)
    }

    @Test func staysOnUntilCooledEnough() throws {
        let clock = FakeClock()
        let (smc, battery, controller) = try rig(.tahoe, config: ChargeConfig(heatLimit: 35), clock: clock)
        battery.reading = BatteryReading(percent: 50, pluggedIn: true, temperatureC: 36)
        controller.tick()
        battery.reading.temperatureC = 33.5 // above 35 - 2
        clock.advance(ChargeConfig.heatCooldown * 2)
        controller.tick()
        #expect(try smc.read("CHTE") == [1, 0, 0, 0])
    }

    @Test func cutsAdapterOnGatedFirmware() throws {
        let clock = FakeClock()
        let (smc, battery, controller) = try rig(.gated, config: ChargeConfig(limit: 90, heatLimit: 35), clock: clock)
        battery.reading = BatteryReading(percent: 50, pluggedIn: true, temperatureC: 38)
        controller.tick()
        #expect(try smc.read("CHIE") == [0x08])
        controller.willSleep()
        #expect(try smc.read("CHIE") == [0x00], "never sleep with the adapter cut")
    }

    @Test func combinesWithLimit() throws {
        let clock = FakeClock()
        let (smc, battery, controller) = try rig(.tahoe, config: ChargeConfig(limit: 80, heatLimit: 40), clock: clock)
        battery.reading = BatteryReading(percent: 85, pluggedIn: true, temperatureC: 30)
        controller.tick()
        #expect(try smc.read("CHTE") == [1, 0, 0, 0], "limit alone holds")
    }

    @Test func missingTemperatureDoesNothing() throws {
        let clock = FakeClock()
        let (smc, battery, controller) = try rig(.tahoe, config: ChargeConfig(heatLimit: 30), clock: clock)
        battery.reading = BatteryReading(percent: 50, pluggedIn: true, temperatureC: nil)
        controller.tick()
        #expect(try smc.read("CHTE") == [0, 0, 0, 0])
    }

    @Test func needsHelper() {
        let gated = Capabilities.detect(FakeSMC(profile: .gated))
        #expect(!ChargeConfig(limit: 85).needsHelper(gated))
        #expect(ChargeConfig(limit: 85, heatLimit: 35).needsHelper(gated))
    }
}

@Suite struct TopUpTests {
    func rig(_ profile: FakeSMC.Profile, config: ChargeConfig, clock: FakeClock)
        throws -> (FakeSMC, FakeBattery, Controller, JSONFile<ChargeConfig>) {
        let smc = FakeSMC(profile: profile)
        let battery = FakeBattery()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = JSONFile<ChargeConfig>(dir.appendingPathComponent("config.json"))
        try file.save(config)
        let controller = Controller(actuator: Actuator(smc: smc, caps: Capabilities.detect(smc)),
                                    configFile: file, marker: JSONFile(dir.appendingPathComponent("m.json")),
                                    now: { clock.now }, log: .quiet, readBattery: { battery.reading })
        return (smc, battery, controller, file)
    }

    @Test func ignoresLimitUntilFull() throws {
        let clock = FakeClock()
        let until = clock.now.addingTimeInterval(ChargeConfig.topUpMaximum)
        let (smc, battery, controller, file) = try rig(.tahoe, config: ChargeConfig(limit: 80, topUpUntil: until), clock: clock)
        battery.reading = BatteryReading(percent: 85, pluggedIn: true)
        controller.start()
        #expect(try smc.read("CHTE") == [0, 0, 0, 0], "charging above the limit")

        battery.reading.percent = 100
        controller.tick()
        #expect(file.load()?.topUpUntil == nil, "ended and saved")
        #expect(try smc.read("CHTE") == [1, 0, 0, 0], "limit is back")
    }

    @Test func endsOnUnplug() throws {
        let clock = FakeClock()
        let (_, battery, controller, file) = try rig(.tahoe, config: ChargeConfig(limit: 80, topUpUntil: clock.now.addingTimeInterval(3600)), clock: clock)
        battery.reading = BatteryReading(percent: 90, pluggedIn: true)
        controller.start()
        battery.reading.pluggedIn = false
        controller.tick()
        #expect(file.load()?.topUpUntil == nil)
    }

    @Test func expires() throws {
        let clock = FakeClock()
        let (smc, battery, controller, _) = try rig(.tahoe, config: ChargeConfig(limit: 80, topUpUntil: clock.now.addingTimeInterval(3600)), clock: clock)
        battery.reading = BatteryReading(percent: 90, pluggedIn: true)
        controller.start()
        clock.advance(3601)
        controller.tick()
        #expect(controller.config.topUpUntil == nil)
        #expect(try smc.read("CHTE") == [1, 0, 0, 0])
    }

    @Test func tellsHelperToRestoreMacOSLimit() throws {
        let clock = FakeClock()
        let (_, battery, controller, _) = try rig(.gated, config: ChargeConfig(limit: 85, topUpUntil: clock.now.addingTimeInterval(3600)), clock: clock)
        let ended = OSAllocatedUnfairLock<ChargeConfig?>(initialState: nil)
        controller.onTopUpEnded = { config in ended.withLock { $0 = config } }
        battery.reading = BatteryReading(percent: 100, pluggedIn: true)
        controller.start()
        #expect(ended.withLock { $0 }?.nativeTarget() == 85)
    }

    @Test func heatStillWinsDuringTopUp() throws {
        let clock = FakeClock()
        let (smc, battery, controller, _) = try rig(.tahoe, config: ChargeConfig(limit: 80, heatLimit: 35, topUpUntil: clock.now.addingTimeInterval(3600)), clock: clock)
        battery.reading = BatteryReading(percent: 85, pluggedIn: true, temperatureC: 40)
        controller.start()
        #expect(try smc.read("CHTE") == [1, 0, 0, 0])
    }

    @Test func nativeTargets() {
        let now = Date()
        #expect(ChargeConfig(limit: 60).nativeTarget(at: now) == 80)
        #expect(ChargeConfig(limit: 90).nativeTarget(at: now) == 90)
        #expect(ChargeConfig(limit: 100).nativeTarget(at: now) == 100)
        #expect(ChargeConfig(limit: 60, topUpUntil: now.addingTimeInterval(60)).nativeTarget(at: now) == 100)
    }
}

@Suite struct DischargeTests {
    @Test func runsOnBatteryDownToTargetThenClears() throws {
        let rig = try Rig(.gated, config: ChargeConfig(limit: 100, dischargeTo: 60))
        rig.battery.reading = BatteryReading(percent: 80, pluggedIn: true)
        rig.controller.start()
        #expect(try rig.smc.read("CHIE") == [0x08])
        #expect(rig.controller.isDischarging)
        rig.set(61, plugged: false)
        #expect(try rig.smc.read("CHIE") == [0x08])
        rig.set(60, plugged: false)
        #expect(try rig.smc.read("CHIE") == [0x00])
        #expect(rig.controller.config.dischargeTo == nil)
        #expect(!rig.controller.isDischarging)
    }

    @Test func thenFollowsTheLimit() throws {
        let rig = try Rig(.tahoe, config: ChargeConfig(limit: 80, dischargeTo: 50))
        rig.controller.start()
        rig.set(50)
        #expect(try rig.smc.read("CHIE") == [0x00])
        #expect(try rig.smc.read("CHTE") == [0, 0, 0, 0], "below the limit, charging resumes")
    }

    @Test func overridesHeatAndLimit() {
        let input = PolicyInput(config: ChargeConfig(limit: 80), method: .inhibit, percent: 90, pluggedIn: true,
                                hot: true, discharging: true, canInhibit: true, canCutAdapter: true, previous: .normal)
        #expect(ChargePolicy.decide(input) == ChargeOutput(chargingAllowed: true, adapterOn: false))
    }

    @Test func pausesForSleep() throws {
        let rig = try Rig(.gated, config: ChargeConfig(dischargeTo: 40))
        rig.battery.reading = BatteryReading(percent: 70, pluggedIn: true)
        rig.controller.start()
        rig.controller.willSleep()
        #expect(try rig.smc.read("CHIE") == [0x00])
        rig.battery.reading = BatteryReading(percent: 70, pluggedIn: true)
        rig.controller.didWake()
        #expect(try rig.smc.read("CHIE") == [0x08], "resumes on wake")
    }

    @Test func clearsWithoutAdapterSwitch() throws {
        let rig = try Rig(.unsupported, config: ChargeConfig(dischargeTo: 40))
        rig.controller.start()
        rig.set(70)
        #expect(rig.controller.config.dischargeTo == nil)
    }
}

@Suite struct MagSafeLEDTests {
    @Test func greenAtLimitOrangeWhileCharging() throws {
        let rig = try Rig(.tahoe, config: ChargeConfig(limit: 80, led: .status))
        rig.controller.start()
        rig.set(60)
        #expect(try rig.smc.read("ACLC") == [MagSafeLED.orange])
        rig.set(80)
        #expect(try rig.smc.read("ACLC") == [MagSafeLED.green])
    }

    @Test func usesIOKitChargingWhenKnown() throws {
        let rig = try Rig(.gated, config: ChargeConfig(limit: 85, led: .status))
        rig.battery.reading = BatteryReading(percent: 70, pluggedIn: true, isCharging: false)
        rig.controller.start()
        #expect(try rig.smc.read("ACLC") == [MagSafeLED.green], "macOS's own limit is holding")
    }

    @Test func writesOnlyOnChange() throws {
        let rig = try Rig(.tahoe, config: ChargeConfig(led: .off))
        rig.controller.start()
        rig.set(50)
        rig.set(51)
        rig.set(52)
        #expect(rig.smc.writes.filter { $0.key == "ACLC" }.count == 1)
    }

    @Test func handsBackToMacOSOnModeChangeAndRestore() throws {
        let rig = try Rig(.tahoe, config: ChargeConfig(led: .off))
        rig.controller.start()
        rig.set(50)
        #expect(try rig.smc.read("ACLC") == [MagSafeLED.off])
        try rig.controller.setConfig(ChargeConfig(led: .system))
        #expect(try rig.smc.read("ACLC") == [MagSafeLED.system])

        try rig.controller.setConfig(ChargeConfig(led: .off))
        rig.controller.restore()
        #expect(try rig.smc.read("ACLC") == [MagSafeLED.system])
    }

    @Test func leavesLEDAloneInSystemMode() throws {
        let rig = try Rig(.tahoe, config: ChargeConfig(limit: 80))
        rig.smc.set("ACLC", type: "ui8 ", [MagSafeLED.green]) // macOS's own value
        rig.controller.start()
        rig.set(85)
        #expect(!rig.smc.writes.contains { $0.key == "ACLC" })
    }

    @Test func refusedLEDKeepsChargingControl() throws {
        let rig = try Rig(.tahoe, config: ChargeConfig(limit: 80, led: .status))
        rig.smc.gate("ACLC")
        rig.controller.start()
        rig.set(85)
        #expect(try rig.smc.read("CHTE") == [1, 0, 0, 0])
        #expect(rig.controller.status().lastError?.contains("LED") == true)
    }

    @Test func darkWhenAdapterCut() {
        #expect(MagSafeLED.value(for: .status, pluggedIn: true, adapterOn: false, charging: false) == nil)
    }
}

extension Logger {
    /// Keeps test runs out of the real helper's log.
    static let quiet = Logger(.disabled)
}
