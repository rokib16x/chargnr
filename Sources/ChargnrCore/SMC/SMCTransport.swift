/// Size and type of an SMC key, as reported by the controller.
public struct SMCKeyInfo: Equatable, Sendable {
    public let size: Int
    public let type: SMCDataType

    public init(size: Int, type: SMCDataType) {
        self.size = size
        self.type = type
    }
}

public enum SMCError: Error, Equatable, Sendable {
    case keyNotFound(SMCKey)
    case sizeMismatch(SMCKey, expected: Int, got: Int)
    case notPrivileged
    case driver(SMCKey, code: Int32)
    case unavailable
}

/// Low-level access to the System Management Controller.
///
/// `AppleSMC` (phase 1) talks to the real driver; `FakeSMC` backs tests and
/// `--fake` runs so nothing touches hardware during development.
public protocol SMCTransport: Sendable {
    /// Returns nil when the key does not exist on this Mac.
    func keyInfo(_ key: SMCKey) throws(SMCError) -> SMCKeyInfo?
    func read(_ key: SMCKey) throws(SMCError) -> [UInt8]
    func write(_ key: SMCKey, _ bytes: [UInt8]) throws(SMCError)
}

/// What probing a key found.
public enum KeyProbe: Equatable, Sendable {
    case present(SMCKeyInfo)
    case missing
    /// Listed, but the driver refuses access even to root. Firmware 20457.1+
    /// does this for the charge-limit keys (entitlement check in AppleSMC).
    case gated
}

public extension SMCTransport {
    /// True only for keys that exist, carry data and can be accessed.
    /// Zero-size placeholders and gated keys count as absent.
    func exists(_ key: SMCKey) -> Bool {
        if case .present(let info) = probe(key) { return info.size > 0 }
        return false
    }

    func probe(_ key: SMCKey) -> KeyProbe {
        do {
            guard let info = try keyInfo(key) else { return .missing }
            return .present(info)
        } catch .notPrivileged {
            return .gated
        } catch {
            return .missing
        }
    }

    /// Writes `bytes` only after checking the key exists and the size matches,
    /// then reads the key back. Throws if the controller did not keep the value.
    func verifiedWrite(_ key: SMCKey, _ bytes: [UInt8]) throws(SMCError) -> Bool {
        guard let info = try keyInfo(key) else { throw .keyNotFound(key) }
        guard info.size == bytes.count else {
            throw .sizeMismatch(key, expected: info.size, got: bytes.count)
        }
        try write(key, bytes)
        return try read(key) == bytes
    }
}
