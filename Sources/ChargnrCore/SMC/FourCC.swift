/// A four-character code packed big-endian into a `UInt32`, as the SMC uses for
/// key names ("CHTE") and data types ("ui32").
public struct FourCC: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Returns nil unless `string` is exactly four ASCII characters.
    public init?(string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        rawValue = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public init(stringLiteral value: StaticString) {
        guard let code = FourCC(string: value.description) else {
            preconditionFailure("FourCC literal must be 4 ASCII characters: \(value)")
        }
        self = code
    }

    public var description: String {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: rawValue >> (24 - $0 * 8)) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public typealias SMCKey = FourCC
public typealias SMCDataType = FourCC
