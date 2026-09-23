import AppIntents
import ChargnrCore
import Foundation

/// Shortcuts actions. They run in the background through the same
/// ConfigUpdater the app and CLI use, so they follow the same rules
/// (macOS's own limit for 80%+ on gated firmware, helper for the rest).

private func updater() -> ConfigUpdater {
    ConfigUpdater(caps: (try? AppleSMC()).map(Capabilities.detect) ?? .none)
}

private func apply(requireHelper: Bool, _ change: @escaping @Sendable (inout ChargeConfig) -> Void) async throws -> ChargeConfig {
    do {
        return try await updater().update(requireHelper: requireHelper, change).config
    } catch {
        throw ChargnrIntentError.failed("\(error)")
    }
}

enum ChargnrIntentError: Error, CustomLocalizedStringResourceConvertible {
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .failed(let message): "\(message)"
        }
    }
}

struct SetChargeLimitIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Charge Limit"
    static let description = IntentDescription("Stops charging at the chosen percentage. 100% charges normally.")

    @Parameter(title: "Limit", description: "Percentage to stop charging at", default: 80, inclusiveRange: (20, 100))
    var percent: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set charge limit to \(\.$percent)%")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let percent = percent
        let config = try await apply(requireHelper: false) { $0.limit = percent }
        return .result(dialog: config.isLimited ? "Charge limit set to \(config.limit)%." : "Charging normally.")
    }
}

struct TopUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Top Up Battery"
    static let description = IntentDescription("Charges to 100% once, then returns to the charge limit.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let until = Date().addingTimeInterval(ChargeConfig.topUpMaximum)
        _ = try await apply(requireHelper: true) {
            $0.topUpUntil = until
            $0.dischargeTo = nil
            $0.calibration = nil
        }
        return .result(dialog: "Charging to 100% once.")
    }
}

struct DischargeIntent: AppIntent {
    static let title: LocalizedStringResource = "Discharge Battery"
    static let description = IntentDescription("Runs the Mac from its battery while plugged in, down to the chosen level.")

    @Parameter(title: "Target", description: "Percentage to discharge to", default: 50, inclusiveRange: (10, 99))
    var percent: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Discharge battery to \(\.$percent)%")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = percent
        _ = try await apply(requireHelper: true) {
            $0.dischargeTo = target
            $0.topUpUntil = nil
            $0.calibration = nil
        }
        return .result(dialog: "Discharging to \(target)%.")
    }
}

struct CalibrateIntent: AppIntent {
    static let title: LocalizedStringResource = "Calibrate Battery"
    static let description = IntentDescription("Discharges to 15%, charges to 100%, holds for an hour, then returns to the limit.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let run = Calibration(startedAt: Date())
        _ = try await apply(requireHelper: true) {
            $0.calibration = run
            $0.topUpUntil = nil
            $0.dischargeTo = nil
        }
        return .result(dialog: "Calibration started. Keep the charger connected.")
    }
}

struct StopOverridesIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Top Up, Discharge or Calibration"
    static let description = IntentDescription("Cancels a top up, discharge or calibration and returns to the charge limit.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let config = try await apply(requireHelper: false) {
            $0.topUpUntil = nil
            $0.dischargeTo = nil
            $0.calibration = nil
        }
        return .result(dialog: config.isLimited ? "Back to the \(config.limit)% limit." : "Charging normally.")
    }
}

struct BatteryStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Battery Status"
    static let description = IntentDescription("Returns the battery percentage and says what chargnr is doing.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let battery = BatteryInfo.current() else { throw ChargnrIntentError.failed("This Mac has no battery.") }
        let config = await updater().current()
        let state = battery.isCharging ? "charging" : battery.externalConnected ? "plugged in, not charging" : "on battery"
        let limit = config.isLimited ? ", limit \(config.limit)%" : ""
        return .result(value: battery.percent, dialog: "Battery \(battery.percent)%, \(state)\(limit).")
    }
}

struct ChargnrShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetChargeLimitIntent(), phrases: ["Set \(.applicationName) charge limit"],
                    shortTitle: "Set Charge Limit", systemImageName: "battery.75percent")
        AppShortcut(intent: TopUpIntent(), phrases: ["Top up with \(.applicationName)"],
                    shortTitle: "Top Up", systemImageName: "battery.100percent.bolt")
        AppShortcut(intent: DischargeIntent(), phrases: ["Discharge with \(.applicationName)"],
                    shortTitle: "Discharge", systemImageName: "arrow.down.circle")
        AppShortcut(intent: BatteryStatusIntent(), phrases: ["\(.applicationName) battery status"],
                    shortTitle: "Battery Status", systemImageName: "info.circle")
    }
}
