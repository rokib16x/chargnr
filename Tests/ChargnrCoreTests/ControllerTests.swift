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
                                readBattery: { battery.reading })
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
