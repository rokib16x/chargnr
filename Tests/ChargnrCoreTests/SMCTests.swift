import ChargnrCore
import Testing

@Suite struct FourCCTests {
    @Test func roundTrips() {
        let key: FourCC = "CHTE"
        #expect(key.rawValue == 0x4348_5445)
        #expect(key.description == "CHTE")
        #expect(FourCC(rawValue: 0x6266_4630).description == "bfF0")
    }

    @Test func rejectsBadStrings() {
        #expect(FourCC(string: "CHT") == nil)
        #expect(FourCC(string: "CHTEX") == nil)
        #expect(FourCC(string: "CHT\u{e9}") == nil)
    }
}

@Suite struct FakeSMCTests {
    @Test(arguments: FakeSMC.Profile.allCases)
    func profilesExposeTheirKeys(profile: FakeSMC.Profile) {
        let smc = FakeSMC(profile: profile)
        #expect(smc.exists("BUIC"))
        #expect(smc.exists("CH0B") == (profile == .legacy))
        #expect(smc.exists("CHTE") == (profile == .tahoe || profile == .firmware))
        #expect(smc.exists("bfF0") == (profile == .firmware))
    }

    @Test func verifiedWriteStoresAndReadsBack() throws {
        let smc = FakeSMC(profile: .tahoe)
        #expect(try smc.verifiedWrite("CHTE", [1, 0, 0, 0]))
        #expect(try smc.read("CHTE") == [1, 0, 0, 0])
        #expect(smc.writes == [.init(key: "CHTE", bytes: [1, 0, 0, 0])])
    }

    @Test func verifiedWriteRefusesMissingKey() {
        let smc = FakeSMC(profile: .tahoe)
        #expect(throws: SMCError.keyNotFound("CH0B")) { try smc.verifiedWrite("CH0B", [2]) }
        #expect(smc.writes.isEmpty)
    }

    @Test func verifiedWriteRefusesWrongSize() {
        let smc = FakeSMC(profile: .tahoe)
        #expect(throws: SMCError.sizeMismatch("CHTE", expected: 4, got: 1)) {
            try smc.verifiedWrite("CHTE", [1])
        }
        #expect(smc.writes.isEmpty)
    }

    @Test func verifiedWriteReportsIgnoredWrite() throws {
        let smc = FakeSMC(profile: .legacy)
        smc.rejectWrites(to: "CH0C")
        #expect(try smc.verifiedWrite("CH0C", [2]) == false)
        #expect(try smc.read("CH0C") == [0])
    }
}
