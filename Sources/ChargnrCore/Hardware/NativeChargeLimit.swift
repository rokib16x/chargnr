import Foundation
import ObjectiveC

/// macOS's own charge limit (System Settings › Battery › Charge Limit), reached
/// through the private PowerUI framework. Works without root, and is the only
/// software limit left on firmware 20457.1+, but only offers 80–100%.
///
/// Private API: every selector's type encoding is checked before it is called,
/// so a future macOS that changes a signature makes this report unavailable
/// instead of crashing.
public struct NativeChargeLimit: Codable, Equatable, Sendable {
    public let enabled: Bool
    /// Target percentage. 100 when the limit is off.
    public let limit: Int
    /// Values System Settings offers, e.g. [80, 85, 90, 95, 100].
    public let available: [Int]

    /// Reads the current setting, or nil when PowerUI or the feature is missing.
    public static func read() -> NativeChargeLimit? {
        guard let client = PowerUIClient() else { return nil }
        return client.read()
    }
}

/// Thin, signature-checked wrapper around `PowerUISmartChargeClient`.
struct PowerUIClient {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"
    private let object: NSObject

    init?() {
        guard dlopen(Self.frameworkPath, RTLD_LAZY) != nil,
              let type = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else { return nil }
        let initSelector = NSSelectorFromString("initWithClientName:")
        guard Self.matches(type, initSelector, "@24@0:8@16"),
              let object = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let client = object.perform(initSelector, with: Chargnr.bundleID)?.takeUnretainedValue() as? NSObject
        else { return nil }
        self.object = client
    }

    func read() -> NativeChargeLimit? {
        guard call("isMCLSupported", "B16@0:8", as: (@convention(c) (NSObject, Selector) -> Bool).self)
                .map({ $0(object, $1) }) == true else { return nil }

        typealias ErrorOut = AutoreleasingUnsafeMutablePointer<NSError?>
        var error: NSError?
        let enabled = call("isMCLCurrentlyEnabled:", "Q24@0:8^@16",
                           as: (@convention(c) (NSObject, Selector, ErrorOut) -> UInt64).self)
            .map { $0(object, $1, &error) }
        let limit = call("getMCLLimitWithError:", "C24@0:8^@16",
                         as: (@convention(c) (NSObject, Selector, ErrorOut) -> UInt8).self)
            .map { $0(object, $1, &error) }
        let available = call("availableChargeLimitsWithError:", "@24@0:8^@16",
                             as: (@convention(c) (NSObject, Selector, ErrorOut) -> NSArray?).self)
            .flatMap { $0(object, $1, &error) }
            .map { $0.compactMap { ($0 as? NSNumber)?.intValue } } ?? []

        guard error == nil, let enabled, let limit else { return nil }
        return NativeChargeLimit(enabled: enabled != 0, limit: Int(limit), available: available)
    }

    /// Looks up `name`, checks its type encoding, and returns its implementation
    /// cast to `T` along with the selector.
    private func call<T>(_ name: String, _ encoding: String, as _: T.Type) -> (T, Selector)? {
        let selector = NSSelectorFromString(name)
        guard Self.matches(type(of: object), selector, encoding),
              let method = class_getInstanceMethod(type(of: object), selector) else { return nil }
        return (unsafeBitCast(method_getImplementation(method), to: T.self), selector)
    }

    private static func matches(_ type: AnyClass, _ selector: Selector, _ encoding: String) -> Bool {
        guard let method = class_getInstanceMethod(type, selector),
              let actual = method_getTypeEncoding(method) else { return false }
        return String(cString: actual) == encoding
    }
}
