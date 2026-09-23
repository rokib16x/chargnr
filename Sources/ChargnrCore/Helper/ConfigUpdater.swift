import Foundation

/// Changes the config from the app or CLI (the logged-in user's side).
///
/// The helper holds the config, but on gated firmware part of the work is
/// macOS's own limit, which only the user can set. This keeps both in step,
/// and checks everything first so a failure changes nothing.
public struct ConfigUpdater: Sendable {
    public let caps: Capabilities
    public let client: HelperClient

    public init(caps: Capabilities, client: HelperClient = HelperClient()) {
        self.caps = caps
        self.client = client
    }

    public enum Failure: Error, CustomStringConvertible, Sendable {
        case helper(HelperClient.Failure)
        case nativeLimit(NativeChargeLimit.SetError)
        case runAsUser

        public var description: String {
            switch self {
            case .helper(let error): "\(error)"
            case .nativeLimit(let error): "macOS refused the charge limit: \(error)"
            case .runAsUser: "run this without sudo: macOS's own limit belongs to your user"
            }
        }
    }

    /// True when this Mac's limits go through macOS's own charge limit.
    public var usesNativeLimit: Bool {
        (caps.charging == .gated || caps.charging == .unsupported) && NativeChargeLimit.read() != nil
    }

    /// The helper's config, or the default when no helper is reachable.
    public func current() async -> ChargeConfig {
        (try? await client.status().config) ?? ChargeConfig()
    }

    /// Puts macOS's own limit back in line with the helper's config, e.g.
    /// after the helper ended a top up (it runs as root and cannot always
    /// reach the user's PowerUI). Returns the value it set, if it changed.
    @discardableResult
    public func syncNativeLimit() async -> Int? {
        guard usesNativeLimit, getuid() != 0, let config = try? await client.status().config,
              let native = NativeChargeLimit.read() else { return nil }
        let target = config.nativeTarget()
        guard native.limit != target else { return nil }
        return (try? NativeChargeLimit.set(target)) != nil ? target : nil
    }

    public struct Outcome: Sendable {
        public let config: ChargeConfig
        public let method: ControlMethod
        public let usesNativeLimit: Bool
        public let helperRunning: Bool
    }

    /// Reads the current config, applies `change`, and stores the result.
    /// - Parameter requireHelper: fail when the helper is missing even if this
    ///   change would not need it, because only the helper can store it.
    @discardableResult
    public func update(requireHelper: Bool = false,
                       _ change: @Sendable (inout ChargeConfig) -> Void) async throws(Failure) -> Outcome {
        let status = try? await client.status()
        var config = status?.config ?? ChargeConfig()
        change(&config)
        config = config.normalized

        let method = ControlMethod.choose(for: config, caps: caps)
        let native = usesNativeLimit
        if config.needsHelper(caps) || requireHelper, status == nil {
            // Surface the real reason (not installed, refused, ...).
            do { _ = try await client.status() } catch { throw .helper(error) }
        }

        // On gated firmware macOS enforces 80%+ itself. Below that it is set
        // to 80% as a floor, so charging stays capped while the Mac sleeps and
        // the helper cannot switch the adapter.
        if native {
            guard getuid() != 0 else { throw .runAsUser }
            do { try NativeChargeLimit.set(config.nativeTarget()) } catch {
                throw .nativeLimit(error)
            }
        }
        if status != nil {
            do { try await client.setConfig(config) } catch { throw .helper(error) }
        }
        return Outcome(config: config, method: method, usesNativeLimit: native, helperRunning: status != nil)
    }
}
