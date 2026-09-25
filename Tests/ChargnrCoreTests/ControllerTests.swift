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
        let target = OSAllocatedUnfairLock<Int?>(initialState: nil)
        controller.onNativeTargetChanged = { value in target.withLock { $0 = value } }
        battery.reading = BatteryReading(percent: 100, pluggedIn: true)
        controller.start()
        #expect(target.withLock { $0 } == 85)
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

@Suite struct SafetyFloorTests {
    func input(_ percent: Int, hot: Bool = false, discharging: Bool = false,
               canInhibit: Bool = false, previous: ChargeOutput = .normal) -> PolicyInput {
        PolicyInput(config: ChargeConfig(limit: 90), method: .none, percent: percent, pluggedIn: true,
                    hot: hot, discharging: discharging, canInhibit: canInhibit, canCutAdapter: true, previous: previous)
    }

    @Test func heatCutsAdapterOnlyAboveFloor() {
        #expect(ChargePolicy.decide(input(41, hot: true)).adapterOn == false)
        #expect(ChargePolicy.decide(input(40, hot: true)).adapterOn == true)
    }

    @Test func heatWithInhibitHasNoFloor() {
        #expect(ChargePolicy.decide(input(20, hot: true, canInhibit: true)) == ChargeOutput(chargingAllowed: false, adapterOn: true))
    }

    @Test func nothingCutsAdapterAtCriticalLevel() {
        let cut = ChargeOutput(chargingAllowed: true, adapterOn: false)
        #expect(ChargePolicy.decide(input(10, hot: true, discharging: true, previous: cut)).adapterOn == true)
        #expect(ChargePolicy.decide(input(11, discharging: true, previous: cut)).adapterOn == false)
    }

    @Test func hotBatteryDrainsOnlyToFloorOnGatedMac() throws {
        let clock = FakeClock()
        let smc = FakeSMC(profile: .gated)
        let battery = FakeBattery()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = JSONFile<ChargeConfig>(dir.appendingPathComponent("c.json"))
        try file.save(ChargeConfig(limit: 85, heatLimit: 30))
        let controller = Controller(actuator: Actuator(smc: smc, caps: Capabilities.detect(smc)), configFile: file,
                                    marker: JSONFile(dir.appendingPathComponent("m.json")), now: { clock.now },
                                    log: .quiet, readBattery: { battery.reading })
        battery.reading = BatteryReading(percent: 60, pluggedIn: true, temperatureC: 35)
        controller.start()
        #expect(try smc.read("CHIE") == [0x08])
        for percent in stride(from: 59, through: 40, by: -1) {
            battery.reading = BatteryReading(percent: percent, pluggedIn: false, temperatureC: 35)
            controller.tick()
        }
        #expect(try smc.read("CHIE") == [0x00], "power back at the floor even though still hot")
    }
}

@Suite struct LEDRefusedTests {
    @Test func errorClearsWhenLEDModeIsDropped() throws {
        let rig = try Rig(.tahoe, config: ChargeConfig(led: .status))
        rig.smc.gate("ACLC")
        rig.controller.start()
        rig.set(60)
        #expect(rig.controller.status().lastError?.contains("LED") == true)
        try rig.controller.setConfig(ChargeConfig(led: .system))
        #expect(rig.controller.status().lastError == nil)
        rig.set(61)
        #expect(rig.controller.status().lastError == nil)
    }
}

@Suite struct CalibrationTests {
    func rig(config: ChargeConfig, clock: FakeClock, profile: FakeSMC.Profile = .gated)
        throws -> (FakeSMC, FakeBattery, Controller, OSAllocatedUnfairLock<[Int]>) {
        let smc = FakeSMC(profile: profile)
        let battery = FakeBattery()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = JSONFile<ChargeConfig>(dir.appendingPathComponent("c.json"))
        try file.save(config)
        let controller = Controller(actuator: Actuator(smc: smc, caps: Capabilities.detect(smc)), configFile: file,
                                    marker: JSONFile(dir.appendingPathComponent("m.json")), now: { clock.now },
                                    log: .quiet, readBattery: { battery.reading })
        let targets = OSAllocatedUnfairLock<[Int]>(initialState: [])
        controller.onNativeTargetChanged = { value in targets.withLock { $0.append(value) } }
        return (smc, battery, controller, targets)
    }

    @Test func runsAllStepsAndReturnsToLimit() throws {
        let clock = FakeClock()
        let (smc, battery, controller, targets) = try rig(
            config: ChargeConfig(limit: 85, calibration: Calibration(dischargeTo: 15, holdMinutes: 60, startedAt: clock.now)),
            clock: clock)
        battery.reading = BatteryReading(percent: 60, pluggedIn: true)
        controller.start()
        #expect(try smc.read("CHIE") == [0x08], "discharging")
        #expect(controller.isDischarging)

        battery.reading = BatteryReading(percent: 15, pluggedIn: true)
        controller.tick()
        #expect(controller.config.calibration?.step == .charge)
        #expect(try smc.read("CHIE") == [0x00], "charging again")
        #expect(targets.withLock { $0 } == [100], "macOS limit lifted for the full charge")

        battery.reading.percent = 100
        clock.advance(3 * 3600)
        controller.tick()
        #expect(controller.config.calibration?.step == .hold)

        clock.advance(59 * 60)
        controller.tick()
        #expect(controller.config.calibration?.step == .hold)
        clock.advance(60)
        controller.tick()
        #expect(controller.config.calibration == nil)
        #expect(controller.config.lastCalibration == clock.now)
        #expect(targets.withLock { $0 } == [100, 85], "limit back")
    }

    @Test func abandonsAfterTimeout() throws {
        let clock = FakeClock()
        let (_, battery, controller, _) = try rig(
            config: ChargeConfig(calibration: Calibration(startedAt: clock.now)), clock: clock)
        battery.reading = BatteryReading(percent: 60, pluggedIn: false)
        controller.start()
        clock.advance(Calibration.timeout + 1)
        controller.tick()
        #expect(controller.config.calibration == nil)
        #expect(controller.config.lastCalibration == nil, "not counted as done")
    }

    @Test func scheduleStartsWhenDueAndPluggedIn() throws {
        let clock = FakeClock()
        let last = clock.now
        let (_, battery, controller, _) = try rig(
            config: ChargeConfig(schedule: CalibrationSchedule(everyDays: 7, hour: 0), lastCalibration: last), clock: clock)
        battery.reading = BatteryReading(percent: 80, pluggedIn: true)
        controller.start()
        #expect(controller.config.calibration == nil)

        clock.advance(8 * 24 * 3600)
        battery.reading.pluggedIn = false
        controller.tick()
        #expect(controller.config.calibration == nil, "waits for the charger")
        battery.reading.pluggedIn = true
        controller.tick()
        #expect(controller.config.calibration?.step == .discharge)
    }

    @Test func scheduleWithoutHistoryStartsCountingNow() throws {
        let clock = FakeClock()
        let (_, battery, controller, _) = try rig(config: ChargeConfig(schedule: CalibrationSchedule(everyDays: 30, hour: 3)), clock: clock)
        battery.reading = BatteryReading(percent: 80, pluggedIn: true)
        controller.start()
        #expect(controller.config.calibration == nil)
        #expect(controller.config.lastCalibration == clock.now)
    }

    @Test func calibrationReplacesTopUpAndDischarge() throws {
        let clock = FakeClock()
        let (_, battery, controller, _) = try rig(config: ChargeConfig(topUpUntil: clock.now.addingTimeInterval(600), dischargeTo: 50), clock: clock)
        battery.reading = BatteryReading(percent: 80, pluggedIn: true)
        controller.startCalibration(Calibration(startedAt: clock.now))
        #expect(controller.config.topUpUntil == nil)
        #expect(controller.config.dischargeTo == nil)
    }

    @Test func nextRunIsAtTheScheduledHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let last = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        let next = CalibrationSchedule(everyDays: 7, hour: 3).nextRun(after: last, calendar: calendar)
        #expect(calendar.component(.hour, from: next) == 3)
        #expect(calendar.component(.day, from: next) == 21)
    }

    @Test func clampsValues() {
        let run = Calibration(dischargeTo: 2, holdMinutes: 999, startedAt: Date())
        #expect(run.dischargeTo == 10)
        #expect(run.holdMinutes == 240)
        #expect(CalibrationSchedule(everyDays: 1, hour: 30) == CalibrationSchedule(everyDays: 7, hour: 23))
    }
}

@Suite struct LidGuardTests {
    @Test func lidClosedNeverCutsTheCharger() {
        for discharging in [false, true] {
            let input = PolicyInput(config: ChargeConfig(limit: 60), method: .adapter, percent: 80, pluggedIn: true,
                                    hot: true, discharging: discharging, lidClosed: true,
                                    canInhibit: false, canCutAdapter: true, previous: .normal)
            #expect(ChargePolicy.decide(input).adapterOn == true)
        }
    }

    @Test func lidClosedStillAllowsStoppingCharging() {
        let input = PolicyInput(config: ChargeConfig(limit: 60), method: .inhibit, percent: 80, pluggedIn: true,
                                lidClosed: true, canInhibit: true, canCutAdapter: true, previous: .normal)
        #expect(ChargePolicy.decide(input) == ChargeOutput(chargingAllowed: false, adapterOn: true))
    }

    @Test func closingTheLidRestoresPowerAndOpeningResumes() throws {
        let rig = try Rig(.gated, config: ChargeConfig(limit: 60))
        rig.battery.reading = BatteryReading(percent: 70, pluggedIn: true)
        rig.controller.start()
        #expect(try rig.smc.read("CHIE") == [0x08], "above the limit: charger cut")

        rig.battery.reading.lidClosed = true
        rig.controller.tick()
        #expect(try rig.smc.read("CHIE") == [0x00], "lid closed: charger back on")
        #expect(rig.controller.status().lidClosed == true)

        rig.battery.reading.lidClosed = false
        rig.controller.tick()
        #expect(try rig.smc.read("CHIE") == [0x08], "lid open again: limit resumes")
    }

    @Test func dischargePausesWithLidClosed() throws {
        let rig = try Rig(.gated, config: ChargeConfig(dischargeTo: 40))
        rig.battery.reading = BatteryReading(percent: 70, pluggedIn: true, lidClosed: true)
        rig.controller.start()
        #expect(try rig.smc.read("CHIE") == [0x00])
        #expect(!rig.controller.isDischarging, "no keep-awake assertion while paused")
        #expect(rig.controller.config.dischargeTo == 40, "still pending, resumes when the lid opens")
    }
}
