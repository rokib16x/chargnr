import IOKit
import os

/// The real System Management Controller, reached through the AppleSMC driver.
///
/// Reads work for any user. Writes need root; without it they throw
/// `SMCError.notPrivileged`. Key info is cached because keys never change
/// while the Mac is running, which halves the driver calls for every read.
public final class AppleSMC: SMCTransport {
    private let connection: io_connect_t
    private let infoCache = OSAllocatedUnfairLock<[SMCKey: SMCKeyInfo?]>(initialState: [:])

    public init() throws(SMCError) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { throw .unavailable }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            throw .unavailable
        }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    public func keyInfo(_ key: SMCKey) throws(SMCError) -> SMCKeyInfo? {
        if let cached = infoCache.withLock({ $0[key] }) { return cached }

        let reply = try call(key, command: .keyInfo) { _ in }
        let info: SMCKeyInfo?
        switch reply.result {
        case Result.success:
            info = SMCKeyInfo(size: Int(reply.load(UInt32.self, at: Layout.dataSize)),
                              type: SMCDataType(rawValue: reply.load(UInt32.self, at: Layout.dataType)))
        case Result.keyNotFound:
            info = nil
        default:
            throw .driver(key, code: Int32(reply.result))
        }
        infoCache.withLock { $0[key] = info }
        return info
    }

    public func read(_ key: SMCKey) throws(SMCError) -> [UInt8] {
        guard let info = try keyInfo(key) else { throw .keyNotFound(key) }
        let reply = try call(key, command: .read) { $0.store(UInt32(info.size), at: Layout.dataSize) }
        guard reply.result == Result.success else { throw .driver(key, code: Int32(reply.result)) }
        return reply.bytes(count: info.size)
    }

    public func write(_ key: SMCKey, _ bytes: [UInt8]) throws(SMCError) {
        guard let info = try keyInfo(key) else { throw .keyNotFound(key) }
        guard info.size == bytes.count, bytes.count <= Layout.maxBytes else {
            throw .sizeMismatch(key, expected: info.size, got: bytes.count)
        }
        let reply = try call(key, command: .write) { buffer in
            buffer.store(UInt32(bytes.count), at: Layout.dataSize)
            for (offset, byte) in bytes.enumerated() {
                buffer.storeBytes(of: byte, toByteOffset: Layout.bytes + offset, as: UInt8.self)
            }
        }
        guard reply.result == Result.success else { throw .driver(key, code: Int32(reply.result)) }
    }

    /// Every key the controller exposes, in index order. Used by `chargnr keys --all`
    /// to find what new firmware renamed or added.
    public func allKeys() throws(SMCError) -> [SMCKey] {
        let countBytes = try read("#KEY")
        guard countBytes.count == 4 else { throw .sizeMismatch("#KEY", expected: 4, got: countBytes.count) }
        let count = countBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var keys: [SMCKey] = []
        keys.reserveCapacity(Int(count))
        for index in 0..<count {
            let reply = try call("#KEY", command: .keyAtIndex) { $0.store(index, at: Layout.data32) }
            guard reply.result == Result.success else { continue }
            keys.append(SMCKey(rawValue: reply.load(UInt32.self, at: Layout.key)))
        }
        return keys
    }

    // MARK: - Driver call

    /// Byte offsets inside the driver's 80-byte parameter block.
    private enum Layout {
        static let size = 80
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let data32 = 44
        static let bytes = 48
        static let maxBytes = 32
    }

    private enum Command: UInt8 {
        case read = 5
        case write = 6
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private enum Result {
        static let success: UInt8 = 0
        static let keyNotFound: UInt8 = 0x84
    }

    /// The driver's "handle event" selector, the one entry point for SMC calls.
    private static let selector: UInt32 = 2

    private struct Reply {
        let raw: [UInt8]
        var result: UInt8 { raw[Layout.result] }

        func load<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
            raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }

        func bytes(count: Int) -> [UInt8] {
            Array(raw[Layout.bytes..<Layout.bytes + min(count, Layout.maxBytes)])
        }
    }

    private func call(_ key: SMCKey, command: Command,
                      fill: (UnsafeMutableRawBufferPointer) -> Void) throws(SMCError) -> Reply {
        var input = [UInt8](repeating: 0, count: Layout.size)
        var output = [UInt8](repeating: 0, count: Layout.size)
        input.withUnsafeMutableBytes { buffer in
            buffer.store(key.rawValue, at: Layout.key)
            buffer.storeBytes(of: command.rawValue, toByteOffset: Layout.command, as: UInt8.self)
            fill(buffer)
        }

        var outputSize = Layout.size
        let status = input.withUnsafeBytes { inBuffer in
            output.withUnsafeMutableBytes { outBuffer in
                IOConnectCallStructMethod(connection, Self.selector,
                                          inBuffer.baseAddress, Layout.size,
                                          outBuffer.baseAddress, &outputSize)
            }
        }
        switch status {
        case kIOReturnSuccess: return Reply(raw: output)
        case kIOReturnNotPrivileged: throw .notPrivileged
        default: throw .driver(key, code: status)
        }
    }
}

private extension UnsafeMutableRawBufferPointer {
    func store(_ value: UInt32, at offset: Int) {
        storeBytes(of: value, toByteOffset: offset, as: UInt32.self)
    }
}
