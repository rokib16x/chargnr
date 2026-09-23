/// Applies `ChargeOutput` to the SMC with verified writes, and knows how to put
/// every switch back to normal. The only code that writes charging keys.
public final class Actuator: Sendable {
    public let smc: any SMCTransport
    public let caps: Capabilities
    private let retries: Int

    public init(smc: any SMCTransport, caps: Capabilities, retries: Int = 3) {
        self.smc = smc
        self.caps = caps
        self.retries = retries
    }

    public enum Failure: Error, Equatable, Sendable {
        case notApplied(SMCKey)
        case smc(SMCError)
    }

    /// Sets charging and adapter. Writes only keys whose value differs, so a
    /// steady state costs reads only.
    public func apply(_ output: ChargeOutput) throws(Failure) {
        for (key, value) in chargingWrites(allowed: output.chargingAllowed) + adapterWrites(on: output.adapterOn) {
            try write(key, value)
        }
    }

    /// Charging allowed, adapter on. Safe to call at any time, even if chargnr
    /// never changed anything.
    public func restoreNormal() throws(Failure) {
        try apply(.normal)
    }

    /// What the hardware says right now. Switches this Mac lacks read as normal.
    public func current() -> ChargeOutput {
        let state = ChargeState.read(smc, caps)
        return ChargeOutput(chargingAllowed: !(state.chargingInhibited ?? false),
                            adapterOn: !(state.adapterDisabled ?? false))
    }

    private func chargingWrites(allowed: Bool) -> [(SMCKey, [UInt8])] {
        if smc.exists(SMCKeys.chargeInhibitTahoe) {
            return [(SMCKeys.chargeInhibitTahoe, allowed ? [0, 0, 0, 0] : [1, 0, 0, 0])]
        }
        if smc.exists(SMCKeys.chargeInhibitB), smc.exists(SMCKeys.chargeInhibitC) {
            let value: [UInt8] = allowed ? [0x00] : [0x02]
            return [(SMCKeys.chargeInhibitB, value), (SMCKeys.chargeInhibitC, value)]
        }
        return []
    }

    private func adapterWrites(on: Bool) -> [(SMCKey, [UInt8])] {
        guard let key = caps.adapterKey else { return [] }
        return [(key, [on ? 0x00 : Adapter.offValue(for: key)])]
    }

    private func write(_ key: SMCKey, _ value: [UInt8]) throws(Failure) {
        if (try? smc.read(key)) == value { return }
        var lastError: SMCError?
        for _ in 0..<retries {
            do {
                if try smc.verifiedWrite(key, value) { return }
            } catch {
                // Missing root will not fix itself; stop retrying.
                if error == .notPrivileged { throw .smc(error) }
                lastError = error
            }
        }
        if let lastError { throw .smc(lastError) }
        throw .notApplied(key)
    }
}
