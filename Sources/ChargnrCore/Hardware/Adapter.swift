/// Switching wall power off and on, so the Mac runs from its battery while
/// plugged in. This is force discharge, and the only SMC-level way to hold a
/// charge limit on firmware that gates the charge keys.
public enum Adapter {
    /// The byte that switches the adapter off for a given key.
    public static func offValue(for key: SMCKey) -> UInt8 {
        key == "CHIE" ? 0x08 : 0x01
    }

    /// Switches the adapter on or off with a verified write. Needs root.
    public static func set(enabled: Bool, smc: some SMCTransport, caps: Capabilities) throws(AdapterError) {
        guard let key = caps.adapterKey else { throw .unsupported }
        let value: UInt8 = enabled ? 0x00 : offValue(for: key)
        do {
            guard try smc.verifiedWrite(key, [value]) else { throw AdapterError.notApplied(key) }
        } catch let error as SMCError {
            throw error == .notPrivileged ? .needsRoot : .smc(error)
        } catch let error as AdapterError {
            throw error
        } catch {
            throw .unsupported
        }
    }
}

public enum AdapterError: Error, Equatable, Sendable {
    case unsupported
    case needsRoot
    /// The controller accepted the write but read back a different value.
    case notApplied(SMCKey)
    case smc(SMCError)
}
