@testable import ChargnrCore
import Foundation
import Testing

@Suite struct ControlMethodTests {
    let tahoe = Capabilities.detect(FakeSMC(profile: .tahoe))
    let gated = Capabilities.detect(FakeSMC(profile: .gated))

    @Test func noLimitMeansHandsOff() {
        #expect(ControlMethod.choose(for: ChargeConfig(limit: 100), caps: tahoe) == .none)
    }

    @Test func inhibitWhereKeysWork() {
        #expect(ControlMethod.choose(for: ChargeConfig(limit: 60), caps: tahoe) == .inhibit)
        #expect(ControlMethod.choose(for: ChargeConfig(limit: 60),
                                     caps: Capabilities.detect(FakeSMC(profile: .legacy))) == .inhibit)
    }

    @Test func gatedUsesMacOSLimitFrom80() {
        #expect(ControlMethod.choose(for: ChargeConfig(limit: 80), caps: gated) == .none)
        #expect(ControlMethod.choose(for: ChargeConfig(limit: 95), caps: gated) == .none)
    }

    @Test func gatedUsesAdapterBelow80() {
        #expect(ControlMethod.choose(for: ChargeConfig(limit: 79), caps: gated) == .adapter)
        #expect(ControlMethod.choose(for: ChargeConfig(limit: 50), caps: gated) == .adapter)
    }
}

@Suite struct ChargePolicyTests {
    let config = ChargeConfig(limit: 80, gap: 5)
    let inhibited = ChargeOutput(chargingAllowed: false, adapterOn: true)
    let adapterOff = ChargeOutput(chargingAllowed: true, adapterOn: false)

    func decide(_ method: ControlMethod, _ percent: Int, plugged: Bool = true,
                previous: ChargeOutput = .normal, config: ChargeConfig? = nil) -> ChargeOutput {
        ChargePolicy.decide(config: config ?? self.config, method: method, percent: percent,
                            pluggedIn: plugged, previous: previous)
    }

    @Test func inhibitStopsAtLimit() {
        #expect(decide(.inhibit, 79) == .normal)
        #expect(decide(.inhibit, 80) == inhibited)
        #expect(decide(.inhibit, 92) == inhibited)
    }

    @Test func inhibitKeepsStateInsideTheBand() {
        #expect(decide(.inhibit, 77, previous: inhibited) == inhibited)
        #expect(decide(.inhibit, 77, previous: .normal) == .normal)
        #expect(decide(.inhibit, 75, previous: inhibited) == .normal)
    }

    @Test func inhibitDoesNothingOnBattery() {
        #expect(decide(.inhibit, 90, plugged: false, previous: inhibited) == .normal)
    }

    @Test func adapterCutsAtLimitAndRestoresBelowBand() {
        let low = ChargeConfig(limit: 60, gap: 5)
        #expect(decide(.adapter, 60, config: low) == adapterOff)
        #expect(decide(.adapter, 57, plugged: false, previous: adapterOff, config: low) == adapterOff)
        #expect(decide(.adapter, 55, plugged: false, previous: adapterOff, config: low) == .normal)
    }

    @Test func adapterBandIsNeverTooNarrow() {
        let tight = ChargeConfig(limit: 60, gap: 1)
        #expect(decide(.adapter, 59, plugged: false, previous: adapterOff, config: tight) == adapterOff)
        #expect(decide(.adapter, 57, plugged: false, previous: adapterOff, config: tight) == .normal)
    }

    @Test func adapterIgnoresUnplugWhileNotCutting() {
        #expect(decide(.adapter, 70, plugged: false, config: ChargeConfig(limit: 60)) == .normal)
    }

    @Test func noneAlwaysNormal() {
        #expect(decide(.none, 100, previous: inhibited) == .normal)
    }

    @Test func configIsClamped() {
        #expect(ChargeConfig(limit: 5, gap: 50).normalized == ChargeConfig(limit: 20, gap: 20))
    }
}

@Suite struct ActuatorTests {
    @Test func inhibitsWithTahoeKey() throws {
        let smc = FakeSMC(profile: .tahoe)
        let actuator = Actuator(smc: smc, caps: Capabilities.detect(smc))
        try actuator.apply(ChargeOutput(chargingAllowed: false, adapterOn: true))
        #expect(try smc.read("CHTE") == [1, 0, 0, 0])
        #expect(actuator.current().chargingAllowed == false)
        #expect(actuator.current().adapterOn == true)
    }

    @Test func inhibitsBothLegacyKeys() throws {
        let smc = FakeSMC(profile: .legacy)
        try Actuator(smc: smc, caps: Capabilities.detect(smc)).apply(ChargeOutput(chargingAllowed: false, adapterOn: true))
        #expect(try smc.read("CH0B") == [2])
        #expect(try smc.read("CH0C") == [2])
    }

    @Test func skipsWritesWhenAlreadySet() throws {
        let smc = FakeSMC(profile: .tahoe)
        try Actuator(smc: smc, caps: Capabilities.detect(smc)).apply(.normal)
        #expect(smc.writes.isEmpty)
    }

    @Test func gatedMacOnlyTouchesAdapter() throws {
        let smc = FakeSMC(profile: .gated)
        let actuator = Actuator(smc: smc, caps: Capabilities.detect(smc))
        try actuator.apply(ChargeOutput(chargingAllowed: false, adapterOn: false))
        #expect(smc.writes == [.init(key: "CHIE", bytes: [0x08])])
        try actuator.restoreNormal()
        #expect(try smc.read("CHIE") == [0])
    }

    @Test func retriesThenReportsIgnoredWrite() {
        let smc = FakeSMC(profile: .tahoe)
        smc.rejectWrites(to: "CHTE")
        let actuator = Actuator(smc: smc, caps: Capabilities.detect(smc), retries: 3)
        #expect(throws: Actuator.Failure.notApplied("CHTE")) {
            try actuator.apply(ChargeOutput(chargingAllowed: false, adapterOn: true))
        }
        #expect(smc.writes.count == 3)
    }
}

@Suite struct JSONFileTests {
    @Test func savesAndLoadsAtomically() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = JSONFile<ChargeConfig>(dir.appendingPathComponent("config.json"))
        #expect(file.load() == nil)
        try file.save(ChargeConfig(limit: 70, gap: 4))
        #expect(file.load() == ChargeConfig(limit: 70, gap: 4))
        file.remove()
        #expect(file.load() == nil)
    }

    @Test func corruptFileLoadsAsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not json".utf8).write(to: url)
        #expect(JSONFile<ChargeConfig>(url).load() == nil)
    }
}

@Suite struct ChargeConfigCodingTests {
    @Test func oldConfigWithoutNewFieldsLoads() throws {
        let config = try JSONDecoder().decode(ChargeConfig.self, from: Data(#"{"limit": 70}"#.utf8))
        #expect(config == ChargeConfig(limit: 70, gap: ChargeConfig.defaultGap))
    }

    @Test func emptyObjectIsDefault() throws {
        #expect(try JSONDecoder().decode(ChargeConfig.self, from: Data("{}".utf8)) == ChargeConfig())
    }

    @Test func roundTrips() throws {
        let config = ChargeConfig(limit: 65, gap: 9)
        #expect(try JSONDecoder().decode(ChargeConfig.self, from: JSONEncoder().encode(config)) == config)
    }
}

@Suite struct SailingTests {
    @Test func sailingOffResumesAfterOnePoint() {
        let config = ChargeConfig(limit: 80, gap: ChargeConfig.noSailingGap)
        let held = ChargeOutput(chargingAllowed: false, adapterOn: true)
        #expect(ChargePolicy.decide(config: config, method: .inhibit, percent: 80, pluggedIn: true, previous: .normal) == held)
        #expect(ChargePolicy.decide(config: config, method: .inhibit, percent: 79, pluggedIn: true, previous: held) == .normal)
    }

    @Test func wideSailingHoldsLonger() {
        let config = ChargeConfig(limit: 80, gap: 15)
        let held = ChargeOutput(chargingAllowed: false, adapterOn: true)
        #expect(ChargePolicy.decide(config: config, method: .inhibit, percent: 66, pluggedIn: true, previous: held) == held)
        #expect(ChargePolicy.decide(config: config, method: .inhibit, percent: 65, pluggedIn: true, previous: held) == .normal)
    }
}
