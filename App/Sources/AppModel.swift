import ChargnrCore
import Foundation
import Observation

/// What the battery is doing, in the words the popover and notifications use.
enum Phase: Equatable {
    case onBattery
    case charging(to: Int)
    case holding(at: Int)
    case notCharging
    case toppingUp
    case discharging(to: Int)
    case heatPause(Double)
    case calibrating(Calibration.Step)
}

/// Where the helper stands, for the install banner.
enum HelperState: Equatable {
    case running
    case notInstalled
    case needsApproval
    case notAnswering
}

/// Everything the UI shows. Refreshed on power events and when the popover
/// opens, never on a tight timer while the menu bar is idle.
@MainActor
@Observable
final class AppModel {
    private(set) var battery: BatteryInfo?
    private(set) var nativeLimit: NativeChargeLimit?
    private(set) var helper: HelperStatus?
    private(set) var helperState: HelperState = .notInstalled
    private(set) var caps: Capabilities
    private(set) var firmware: String?
    /// Shown briefly after a failed action.
    var errorMessage: String?
    private(set) var busy = false

    /// Called after every refresh with the new phase, for notifications and the status item.
    var onChange: ((AppModel) -> Void)?

    private let smc: AppleSMC?
    private let client = HelperClient()

    init() {
        smc = try? AppleSMC()
        caps = smc.map(Capabilities.detect) ?? .none
        firmware = SystemInfo.firmwareVersion()
    }

    /// The config the UI edits: the helper's, or a default when it is missing.
    var config: ChargeConfig { helper?.config ?? ChargeConfig(limit: nativeLimit.map { $0.enabled ? $0.limit : 100 } ?? 100) }

    var usesNativeLimit: Bool {
        (caps.charging == .gated || caps.charging == .unsupported) && nativeLimit != nil
    }

    var temperatureC: Double? {
        helper?.temperatureC ?? smc.flatMap { ChargeState.read($0, caps).temperatureC }
    }

    var phase: Phase {
        guard let battery else { return .notCharging }
        if let run = helper?.calibration { return .calibrating(run.step) }
        if let target = helper?.dischargeTo { return .discharging(to: target) }
        if helper?.heatHold == true, let t = temperatureC { return .heatPause(t) }
        if helper?.topUpUntil != nil { return .toppingUp }
        let limit = config.limit
        if !battery.externalConnected && helper?.output.adapterOn != false { return .onBattery }
        if battery.isCharging { return .charging(to: limit) }
        if config.isLimited && battery.percent >= config.resumeBelow { return .holding(at: limit) }
        if battery.fullyCharged || battery.percent >= 100 { return .holding(at: 100) }
        return .notCharging
    }

    // MARK: - Refresh

    func refresh() async {
        battery = BatteryInfo.current()
        nativeLimit = NativeChargeLimit.read()
        if Installer.isInstalled || HelperInstaller.isEnabled {
            do {
                helper = try await client.status()
                helperState = .running
                // Put macOS's limit back if the helper ended a top up while we were away.
                if await updater.syncNativeLimit() != nil { nativeLimit = NativeChargeLimit.read() }
            } catch {
                helper = nil
                helperState = .notAnswering
            }
        } else {
            helper = nil
            helperState = HelperInstaller.needsApproval ? .needsApproval : .notInstalled
        }
        onChange?(self)
    }

    // MARK: - Actions

    private var updater: ConfigUpdater { ConfigUpdater(caps: caps, client: client) }

    func setLimit(_ limit: Int) async {
        await change(requireHelper: false) { $0.limit = limit }
    }

    func setSailing(_ gap: Int) async {
        await change(requireHelper: true) { $0.gap = gap }
    }

    func setHeatLimit(_ celsius: Int?) async {
        await change(requireHelper: celsius != nil) { $0.heatLimit = celsius }
    }

    func topUp(_ on: Bool) async {
        let until = Date().addingTimeInterval(ChargeConfig.topUpMaximum)
        await change(requireHelper: on) {
            $0.topUpUntil = on ? until : nil
            if on {
                $0.dischargeTo = nil
                $0.calibration = nil
            }
        }
    }

    func discharge(to target: Int?) async {
        await change(requireHelper: target != nil) {
            $0.dischargeTo = target
            if target != nil {
                $0.topUpUntil = nil
                $0.calibration = nil
            }
        }
    }

    func calibrate(_ on: Bool) async {
        let run = Calibration(startedAt: Date())
        await change(requireHelper: true) {
            $0.calibration = on ? run : nil
            if on {
                $0.topUpUntil = nil
                $0.dischargeTo = nil
            }
        }
    }

    func setSchedule(everyDays days: Int?) async {
        await change(requireHelper: days != nil) {
            $0.schedule = days.map { CalibrationSchedule(everyDays: $0, hour: 3) }
            if days != nil, $0.lastCalibration == nil { $0.lastCalibration = Date() }
        }
    }

    func setLED(_ mode: ChargeConfig.LEDMode) async {
        await change(requireHelper: mode != .system) { $0.led = mode }
    }

    private func change(requireHelper: Bool, _ edit: @escaping @Sendable (inout ChargeConfig) -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await updater.update(requireHelper: requireHelper, edit)
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
        await refresh()
    }
}
