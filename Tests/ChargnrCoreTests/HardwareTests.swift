@testable import ChargnrCore
import Testing

@Suite struct CapabilitiesTests {
    @Test func legacyFirmware() {
        let caps = Capabilities.detect(FakeSMC(profile: .legacy))
        #expect(caps.charging == .legacy)
        #expect(caps.canInhibit)
        #expect(caps.adapterKey == "CH0I")
        #expect(caps.magSafeLED)
    }

    @Test func tahoeFirmware() {
        let caps = Capabilities.detect(FakeSMC(profile: .tahoe))
        #expect(caps.charging == .tahoe)
        #expect(caps.adapterKey == "CHIE")
    }

    @Test func firmwareLimitWinsOverInhibit() {
        let caps = Capabilities.detect(FakeSMC(profile: .firmwareLimit))
        #expect(caps.charging == .firmwareLimit)
        #expect(caps.canInhibit, "CHTE is still there for manual control")
    }

    @Test func adapterOnlyFirmwareIsUnsupported() {
        let caps = Capabilities.detect(FakeSMC(profile: .adapterOnly))
        #expect(caps.charging == .unsupported)
        #expect(!caps.canInhibit)
        #expect(caps.canDisableAdapter)
    }

    @Test func partialFirmwareLimitIsNotTrusted() {
        let smc = FakeSMC(profile: .tahoe)
        smc.set("bfF0", type: "ui8 ", [0])
        smc.set("bfD0", type: "ui32", [80, 0, 0, 0])
        #expect(Capabilities.detect(smc).charging == .tahoe, "bfE0 is missing")
    }

    @Test func adapterKeysProbeInOrder() {
        let smc = FakeSMC(profile: .tahoe)
        smc.set("CH0J", type: "hex_", [0])
        #expect(Capabilities.detect(smc).adapterKey == "CH0J")
    }
}

@Suite struct ChargeStateTests {
    @Test func firmwareLimitIsLittleEndian() {
        #expect(FirmwareLimit.encode(80) == [0x50, 0, 0, 0])
        #expect(FirmwareLimit.decode([0x50, 0, 0, 0]) == 80)
        #expect(FirmwareLimit.decode([0x50, 0]) == nil)
    }

    @Test func readsFirmwareLimit() {
        let smc = FakeSMC(profile: .firmwareLimit)
        smc.set("bfF0", type: "ui8 ", [FirmwareLimit.activeFlag])
        smc.set("bfD0", type: "ui32", FirmwareLimit.encode(80))
        smc.set("bfE0", type: "ui32", FirmwareLimit.encode(75))
        let state = ChargeState.read(smc, Capabilities.detect(smc))
        #expect(state.firmwareLimit == FirmwareLimit(active: true, lower: 75, upper: 80))
    }

    @Test func readsInhibitAndAdapter() {
        let smc = FakeSMC(profile: .legacy, charge: 81, pluggedIn: true)
        smc.set("CH0B", type: "hex_", [2])
        smc.set("CH0I", type: "hex_", [1])
        let state = ChargeState.read(smc, Capabilities.detect(smc))
        #expect(state.percent == 81)
        #expect(state.pluggedIn == true)
        #expect(state.chargingInhibited == true)
        #expect(state.adapterDisabled == true)
        #expect(state.firmwareLimit == nil)
    }

    @Test func tahoeInhibit() {
        let smc = FakeSMC(profile: .tahoe, pluggedIn: false)
        smc.set("CHTE", type: "ui32", [1, 0, 0, 0])
        let state = ChargeState.read(smc, Capabilities.detect(smc))
        #expect(state.chargingInhibited == true)
        #expect(state.pluggedIn == false)
    }

    @Test func temperatureFloat() {
        let state = ChargeState.read(FakeSMC(profile: .tahoe), Capabilities.detect(FakeSMC(profile: .tahoe)))
        #expect(state.temperatureC == 30.5)
    }

    @Test func temperatureFixedPoint() {
        let smc = FakeSMC(profile: .legacy)
        smc.set("TB0T", type: "sp78", [0x1E, 0x80]) // 30.5 °C
        #expect(ChargeState.read(smc, Capabilities.detect(smc)).temperatureC == 30.5)
    }

    @Test func implausibleTemperatureIsDropped() {
        let smc = FakeSMC(profile: .legacy)
        smc.set("TB0T", type: "sp78", [0, 0])
        #expect(ChargeState.read(smc, Capabilities.detect(smc)).temperatureC == nil)
    }
}
