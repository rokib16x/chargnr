import os

/// An in-memory SMC for tests and `--fake` runs.
///
/// Profiles mirror the key sets real Macs expose, so detection and charging
/// logic can be exercised for every generation without hardware.
public final class FakeSMC: SMCTransport {
    public enum Profile: String, CaseIterable, Sendable {
        /// M1–M3 era firmware: CH0B/CH0C charging, CH0I adapter.
        case legacy
        /// macOS 26 Tahoe firmware: CHTE charging, CHIE adapter.
        case tahoe
        /// Early macOS 27 firmware (before 20457.0.125): bfF0/bfD0/bfE0 limit.
        case firmwareLimit
        /// Firmware 20457.1+: the limit keys and CH0J are gated, the old inhibit
        /// keys are gone, and only CHIE and ACLC still work.
        case gated
        /// No known charging keys.
        case unsupported
    }

    public struct Write: Equatable, Sendable {
        public let key: SMCKey
        public let bytes: [UInt8]

        public init(key: SMCKey, bytes: [UInt8]) {
            self.key = key
            self.bytes = bytes
        }
    }

    private struct Entry {
        var info: SMCKeyInfo
        var bytes: [UInt8]
    }

    private struct State {
        var keys: [SMCKey: Entry] = [:]
        var writes: [Write] = []
        var rejected: Set<SMCKey> = []
        var gated: Set<SMCKey> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public convenience init(profile: Profile, charge: UInt8 = 72, pluggedIn: Bool = true) {
        self.init()
        set("BUIC", type: "ui8 ", [charge])
        set("AC-W", type: "si8 ", [pluggedIn ? 1 : 0])
        set("TB0T", type: "flt ", withUnsafeBytes(of: Float(30.5).bitPattern.littleEndian, Array.init))
        switch profile {
        case .legacy:
            set("CH0B", type: "hex_", [0])
            set("CH0C", type: "hex_", [0])
            set("CH0I", type: "hex_", [0])
            set("ACLC", type: "ui8 ", [0])
        case .tahoe:
            set("CHTE", type: "ui32", [0, 0, 0, 0])
            set("CHIE", type: "hex_", [0])
            set("ACLC", type: "ui8 ", [0])
        case .firmwareLimit:
            set("CHTE", type: "ui32", [0, 0, 0, 0])
            set("CHIE", type: "hex_", [0])
            set("bfF0", type: "ui8 ", [0])
            set("bfD0", type: "ui32", [100, 0, 0, 0])
            set("bfE0", type: "ui32", [100, 0, 0, 0])
        case .gated:
            set("CHIE", type: "hex_", [0])
            set("ACLC", type: "ui8 ", [3])
            for key: SMCKey in ["bfF0", "bfD0", "bfE0", "CH0J"] { gate(key) }
        case .unsupported:
            break
        }
    }

    /// Adds or replaces a key.
    public func set(_ key: SMCKey, type: SMCDataType, _ bytes: [UInt8]) {
        state.withLock {
            $0.keys[key] = Entry(info: SMCKeyInfo(size: bytes.count, type: type), bytes: bytes)
        }
    }

    /// Makes the controller silently ignore writes to `key`, like firmware that
    /// refuses a value. Useful for testing read-back verification.
    public func rejectWrites(to key: SMCKey) {
        _ = state.withLock { $0.rejected.insert(key) }
    }

    /// Makes every access to `key` fail with `notPrivileged`, like the
    /// entitlement check on firmware 20457.1+.
    public func gate(_ key: SMCKey) {
        _ = state.withLock { $0.gated.insert(key) }
    }

    /// Every write that reached the controller, in order.
    public var writes: [Write] {
        state.withLock { $0.writes }
    }

    public func keyInfo(_ key: SMCKey) throws(SMCError) -> SMCKeyInfo? {
        let (gated, info) = state.withLock { ($0.gated.contains(key), $0.keys[key]?.info) }
        if gated { throw .notPrivileged }
        return info
    }

    public func read(_ key: SMCKey) throws(SMCError) -> [UInt8] {
        let (gated, bytes) = state.withLock { ($0.gated.contains(key), $0.keys[key]?.bytes) }
        if gated { throw .notPrivileged }
        guard let bytes else { throw .keyNotFound(key) }
        return bytes
    }

    public func write(_ key: SMCKey, _ bytes: [UInt8]) throws(SMCError) {
        let result: SMCError? = state.withLock {
            if $0.gated.contains(key) { return .notPrivileged }
            guard let entry = $0.keys[key] else { return .keyNotFound(key) }
            guard entry.info.size == bytes.count else {
                return .sizeMismatch(key, expected: entry.info.size, got: bytes.count)
            }
            $0.writes.append(Write(key: key, bytes: bytes))
            if !$0.rejected.contains(key) { $0.keys[key]?.bytes = bytes }
            return nil
        }
        if let result { throw result }
    }
}
