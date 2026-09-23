import Foundation

/// The helper's XPC interface. Deliberately high level: callers can set a
/// config or ask for normal charging, never write raw SMC keys.
/// Payloads are JSON so the app, CLI and helper can evolve independently.
@objc public protocol HelperProtocol {
    /// Replies with JSON-encoded `HelperStatus`.
    func status(reply: @escaping @Sendable (Data?) -> Void)
    /// Takes a JSON-encoded `ChargeConfig`. Replies nil on success, or an error message.
    func setConfig(_ json: Data, reply: @escaping @Sendable (String?) -> Void)
    /// Charging on, adapter on, until the next config change.
    func restoreNormal(reply: @escaping @Sendable (String?) -> Void)
}

public enum HelperService {
    /// launchd label and Mach service name.
    public static let name = Chargnr.helperID
    public static let plistName = "\(Chargnr.helperID).plist"
    /// Code-signing identifiers allowed to talk to the helper.
    public static let clientIdentifiers = [Chargnr.bundleID, "\(Chargnr.bundleID).cli"]

    public static func interface() -> NSXPCInterface {
        NSXPCInterface(with: HelperProtocol.self)
    }
}

/// Talks to the helper from the app or CLI.
public final class HelperClient: Sendable {
    public enum Failure: Error, CustomStringConvertible, Sendable {
        case notRunning
        case refused(String)
        case badReply

        public var description: String {
            switch self {
            case .notRunning: "the chargnr helper is not running (install it with `sudo chargnr install`)"
            case .refused(let message): message
            case .badReply: "the helper sent a reply chargnr does not understand"
            }
        }
    }

    public init() {}

    public func status() async throws(Failure) -> HelperStatus {
        let data: Data? = try await call { proxy, done in proxy.status { done($0) } }
        guard let data, let status = try? JSONDecoder().decode(HelperStatus.self, from: data) else {
            throw .badReply
        }
        return status
    }

    public func setConfig(_ config: ChargeConfig) async throws(Failure) {
        let json = (try? JSONEncoder().encode(config)) ?? Data()
        let error: String? = try await call { proxy, done in proxy.setConfig(json) { done($0) } }
        if let error { throw .refused(error) }
    }

    public func restoreNormal() async throws(Failure) {
        let error: String? = try await call { proxy, done in proxy.restoreNormal { done($0) } }
        if let error { throw .refused(error) }
    }

    /// Opens a connection, makes one call and closes it. Connection errors
    /// (helper missing, caller refused) resolve the call instead of hanging.
    private func call<T: Sendable>(
        _ body: @escaping @Sendable (HelperProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) async throws(Failure) -> T {
        let connection = NSXPCConnection(machServiceName: HelperService.name, options: .privileged)
        connection.remoteObjectInterface = HelperService.interface()
        connection.resume()
        defer { connection.invalidate() }

        let result: Result<T, Failure> = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                let code = (error as NSError).code
                once.resume(.failure(code == NSXPCConnectionInvalid ? .notRunning
                                     : .refused("helper connection failed: \(error.localizedDescription)")))
            }
            guard let helper = proxy as? HelperProtocol else {
                once.resume(.failure(.badReply))
                return
            }
            body(helper) { once.resume(.success($0)) }
        }
        return try result.get()
    }
}

/// Resumes a continuation exactly once, whichever reply comes first.
private final class Once<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Result<T, HelperClient.Failure>, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Result<T, HelperClient.Failure>, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, HelperClient.Failure>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}
