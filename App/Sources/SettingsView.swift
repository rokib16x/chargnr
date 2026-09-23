import ChargnrCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    var onDisplayChange: () -> Void = {}

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showPercent = Preferences.bool(.showPercent)
    @State private var notify: [Preferences.Key: Bool] = Dictionary(uniqueKeysWithValues:
        [Preferences.Key.notifyLimit, .notifyHeat, .notifyTopUp, .notifyDischarge, .notifyHelper].map { ($0, Preferences.bool($0)) })
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open chargnr at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Show battery percentage in the menu bar", isOn: $showPercent)
                    .onChange(of: showPercent) { _, on in
                        Preferences.set(.showPercent, on)
                        onDisplayChange()
                    }
            }

            Section("Notifications") {
                notifyToggle(.notifyLimit, "Charge limit reached")
                notifyToggle(.notifyHeat, "Charging paused because the battery is hot")
                notifyToggle(.notifyTopUp, "Top up finished")
                notifyToggle(.notifyDischarge, "Discharge finished")
                notifyToggle(.notifyHelper, "Helper stopped")
            }

            if model.caps.magSafeLED {
                Section("MagSafe light") {
                    Picker("Light", selection: Binding(get: { model.config.led },
                                                       set: { mode in Task { await model.setLED(mode) } })) {
                        Text("macOS decides").tag(ChargeConfig.LEDMode.system)
                        Text("Green at the limit").tag(ChargeConfig.LEDMode.status)
                        Text("Off").tag(ChargeConfig.LEDMode.off)
                    }
                    .disabled(model.helperState != .running || ledRefused)
                    if ledRefused {
                        Text("This Mac does not let apps change the MagSafe light.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Helper") {
                LabeledContent("Status", value: helperText)
                LabeledContent("Charging control", value: controlText)
                if let firmware = model.firmware { LabeledContent("Firmware", value: firmware) }
                if model.helperState == .running {
                    Button("Remove Helper…") {
                        Task {
                            try? await HelperInstaller.uninstall()
                            await model.refresh()
                        }
                    }
                }
            }

            Section {
                LabeledContent("Version", value: Chargnr.version)
                Link("Source code on GitHub", destination: URL(string: "https://github.com/rokib16x/chargnr")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var ledRefused: Bool { model.helper?.lastError?.contains("LED") == true }

    private var controlText: String {
        switch model.caps.charging {
        case .gated: "macOS limit + charger switch"
        case .firmwareLimit: "Firmware limit"
        case .tahoe, .legacy: "Charge switch"
        case .unsupported: model.caps.canDisableAdapter ? "Charger switch only" : "Not supported"
        }
    }

    private var helperText: String {
        switch model.helperState {
        case .running: "Running"
        case .notInstalled: "Not installed"
        case .needsApproval: "Waiting for approval in Login Items"
        case .notAnswering: "Not answering"
        }
    }

    private func notifyToggle(_ key: Preferences.Key, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { notify[key] ?? true }, set: { on in
            notify[key] = on
            Preferences.set(key, on)
        }))
    }

    /// Reads the real state back, so the toggle never drifts from what macOS has.
    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != launchAtLogin { launchAtLogin = actual }
    }
}
