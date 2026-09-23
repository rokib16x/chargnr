import Foundation
import UserNotifications

/// Posts a notification when the battery changes phase in a way worth telling
/// the user about. Each kind can be switched off in Settings.
@MainActor
final class Notifier {
    private var lastPhase: Phase?
    private var lastHelperState: HelperState?
    private var authorized = false

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func update(_ model: AppModel) {
        let phase = model.phase
        defer {
            lastPhase = phase
            lastHelperState = model.helperState
        }
        // No notifications for the first reading after launch.
        guard let previous = lastPhase else { return }

        switch (previous, phase) {
        case (.charging, .holding(let limit)) where limit < 100:
            post(.notifyLimit, "Charge limit reached", "Holding the battery at \(limit)%.")
        case (let from, .heatPause(let t)) where !isHeatPause(from):
            post(.notifyHeat, "Battery is hot", String(format: "Charging paused at %.0f °C until it cools down.", t))
        case (.toppingUp, let to) where !isToppingUp(to):
            post(.notifyTopUp, "Top up finished", "Back to the \(model.config.limit)% limit.")
        case (.calibrating, let to) where !isCalibrating(to):
            post(.notifyDischarge, "Calibration finished", "Back to the \(model.config.limit)% limit.")
        case (.discharging(let target), let to) where !isDischarging(to):
            post(.notifyDischarge, "Discharge finished", "The battery is down to \(target)%; power is back on.")
        default:
            break
        }

        if lastHelperState == .running, model.helperState == .notAnswering {
            post(.notifyHelper, "chargnr helper stopped", "Charging is back to normal until the helper runs again.")
        }
    }

    private func isHeatPause(_ phase: Phase) -> Bool { if case .heatPause = phase { true } else { false } }
    private func isToppingUp(_ phase: Phase) -> Bool { phase == .toppingUp }
    private func isDischarging(_ phase: Phase) -> Bool { if case .discharging = phase { true } else { false } }
    private func isCalibrating(_ phase: Phase) -> Bool { if case .calibrating = phase { true } else { false } }

    private func post(_ key: Preferences.Key, _ title: String, _ body: String) {
        guard Preferences.bool(key), authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
