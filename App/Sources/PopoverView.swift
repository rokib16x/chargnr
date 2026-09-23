import ChargnrCore
import SwiftUI

struct PopoverView: View {
    @Bindable var model: AppModel
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}

    /// The slider moves freely; the limit is applied when the drag ends.
    @State private var draftLimit: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.helperState != .running { HelperBanner(model: model) }
            if let message = model.errorMessage { ErrorRow(message: message) { model.errorMessage = nil } }
            limitSection
            Divider()
            actions
            Divider()
            details
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            BatteryGauge(percent: model.battery?.percent ?? 0, limit: model.config.isLimited ? model.config.limit : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.battery.map { "\($0.percent)%" } ?? "No battery")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(phaseText).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
        }
    }

    private var phaseText: String {
        switch model.phase {
        case .onBattery:
            model.battery?.minutesRemaining.map { "On battery · \($0 / 60)h \($0 % 60)m left" } ?? "On battery"
        case .charging(let limit): limit < 100 ? "Charging to \(limit)%" : "Charging"
        case .holding(let limit): limit < 100 ? "Holding at \(limit)%" : "Fully charged"
        case .notCharging: "Plugged in, not charging"
        case .toppingUp: "Topping up to 100%"
        case .discharging(let target): "Discharging to \(target)%"
        case .heatPause(let t): String(format: "Paused: battery at %.0f °C", t)
        }
    }

    // MARK: - Limit

    private var limitSection: some View {
        let limit = draftLimit.map { Int($0) } ?? model.config.limit
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Charge limit").font(.headline)
                Spacer()
                Text(limit == 100 ? "Off" : "\(limit)%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { draftLimit ?? Double(model.config.limit) }, set: { draftLimit = $0.rounded() }),
                   in: Double(ChargeConfig.limitRange.lowerBound)...100) { editing in
                guard !editing, let draft = draftLimit else { return }
                Task {
                    await model.setLimit(Int(draft))
                    draftLimit = nil
                }
            }
            Text(limitNote(limit)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if model.config.isLimited && !macOSDecidesResume {
                Stepper(value: Binding(get: { model.config.gap },
                                       set: { gap in Task { await model.setSailing(gap) } }),
                        in: ChargeConfig.gapRange) {
                    Text("Sailing: resume below \(model.config.resumeBelow)%").font(.callout)
                }
                .disabled(model.helperState != .running)
            }
        }
    }

    /// With macOS's own limit in charge (80%+ on gated firmware), macOS picks
    /// when to resume, so sailing has nothing to set.
    private var macOSDecidesResume: Bool {
        model.usesNativeLimit && model.config.limit >= NativeLimitRange.minimum
    }

    private func limitNote(_ limit: Int) -> String {
        guard limit < 100 else { return "The battery charges to 100%." }
        if model.usesNativeLimit {
            return limit >= NativeLimitRange.minimum
                ? "macOS holds this limit, also while the Mac sleeps."
                : "Below 80%, chargnr switches the charger off at the limit. macOS stops at 80% while the Mac sleeps."
        }
        return "Charging stops at \(limit)% and resumes below \(model.config.resumeBelow)%."
    }

    // MARK: - Actions

    private var actions: some View {
        let running = model.helperState == .running
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.phase == .toppingUp {
                    Button("Stop Top Up") { Task { await model.topUp(false) } }
                } else {
                    Button("Top Up to 100%") { Task { await model.topUp(true) } }
                        .disabled(!running || !model.config.isLimited || (model.battery?.percent ?? 100) >= 100)
                }
                Spacer()
                if case .discharging = model.phase {
                    Button("Stop Discharge") { Task { await model.discharge(to: nil) } }
                } else {
                    Menu("Discharge") {
                        ForEach(dischargeTargets, id: \.self) { target in
                            Button("To \(target)%") { Task { await model.discharge(to: target) } }
                        }
                    }
                    .fixedSize()
                    .disabled(!running || !model.caps.canDisableAdapter || dischargeTargets.isEmpty)
                }
            }
            HStack {
                Toggle("Heat protection", isOn: Binding(
                    get: { model.config.heatLimit != nil },
                    set: { on in Task { await model.setHeatLimit(on ? 35 : nil) } }))
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(!running)
                Spacer()
                if let heat = model.config.heatLimit {
                    Picker("", selection: Binding(get: { heat }, set: { t in Task { await model.setHeatLimit(t) } })) {
                        ForEach(Array(stride(from: 30, through: 45, by: 1)), id: \.self) { Text("\($0) °C").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }

    private var dischargeTargets: [Int] {
        let percent = model.battery?.percent ?? 0
        return [80, 60, 50, 40, 20].filter { $0 < percent }
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let battery = model.battery {
                PowerFlow(battery: battery, adapterOn: model.helper?.output.adapterOn ?? true)
                DetailRow("Health", battery.healthPercent.map { "\($0)% · \(battery.cycleCount) cycles" })
                DetailRow("Temperature", model.temperatureC.map { String(format: "%.1f °C", $0) })
                DetailRow("Charger", battery.adapterName)
            }
            if let native = model.nativeLimit, model.usesNativeLimit {
                DetailRow("macOS limit", native.enabled ? "\(native.limit)%" : "Off")
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: openSettings)
            Spacer()
            Button("Quit chargnr", action: quit)
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

// MARK: - Pieces

struct BatteryGauge: View {
    let percent: Int
    let limit: Int?

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let limit {
                // Tick at the limit.
                Capsule().fill(.primary).frame(width: 2, height: 9)
                    .offset(y: -22)
                    .rotationEffect(.degrees(Double(limit) / 100 * 360))
            }
            Image(systemName: "bolt.fill").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(width: 44, height: 44)
    }

    private var color: Color {
        percent <= 20 ? .red : percent <= 40 ? .orange : .green
    }
}

struct PowerFlow: View {
    let battery: BatteryInfo
    let adapterOn: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label(watts(battery.systemPowerInMW.flatMap { battery.externalConnected && adapterOn ? $0 : 0 }),
                  systemImage: "powerplug")
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Label(watts(battery.systemLoadMW), systemImage: "laptopcomputer")
            Spacer()
            Label(String(format: "%+.1f W", Double(battery.batteryPowerMW) / 1000),
                  systemImage: battery.batteryPowerMW >= 0 ? "battery.100percent.bolt" : "battery.50percent")
        }
        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        .help("Charger in → Mac using · battery in (+) or out (−)")
    }

    private func watts(_ mw: Int?) -> String {
        mw.map { String(format: "%.1f W", Double($0) / 1000) } ?? "–"
    }
}

struct DetailRow: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if let value {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(.callout)
        }
    }
}

struct ErrorRow: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
    }
}

struct HelperBanner: View {
    let model: AppModel
    @State private var installing = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            Button(buttonTitle) {
                installing = true
                Task {
                    do { try await HelperInstaller.install() } catch { failure = "\(error)" }
                    installing = false
                    await model.refresh()
                }
            }
            .disabled(installing)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var title: String {
        switch model.helperState {
        case .needsApproval: "Approve the chargnr helper"
        case .notAnswering: "The chargnr helper is not answering"
        default: "Install the chargnr helper"
        }
    }

    private var detail: String {
        model.usesNativeLimit
            ? "Limits of 80% and above already work through macOS. The helper adds lower limits, sailing, heat protection, top up and discharge."
            : "The helper runs in the background and switches charging. It needs your administrator password once."
    }

    private var buttonTitle: String {
        switch model.helperState {
        case .needsApproval: "Open Login Items"
        case .notAnswering: "Reinstall Helper"
        default: "Install Helper…"
        }
    }
}
