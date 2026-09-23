import AppKit
import ChargnrCore
import IOKit.ps
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let notifier = Notifier()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var powerSource: CFRunLoopSource?
    private var liveTimer: Timer?
    private var idleTimer: Timer?
    private var lastTitle: (symbol: String, text: String)?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = snapshotPath() {
            Task { await snapshot(to: path) }
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        statusItem = item

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            model: model, openSettings: { [weak self] in self?.openSettings() }, quit: { NSApp.terminate(nil) }))
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopLiveUpdates() }
        }

        model.onChange = { [weak self] model in
            self?.updateStatusItem(model)
            self?.notifier.update(model)
        }
        notifier.requestPermission()
        listenForPowerChanges()
        // Helper events (heat, discharge finishing) are not pushed, so check
        // now and then; leeway lets macOS batch the wakeup with others.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.model.refresh() }
        }
        idleTimer?.tolerance = 15
        Task { await model.refresh() }
    }

    // MARK: - Status item

    private func updateStatusItem(_ model: AppModel) {
        let percent = model.battery?.percent ?? 0
        let symbol: String = switch model.phase {
        case .charging, .toppingUp: "battery.100percent.bolt"
        case .heatPause: "thermometer.high"
        case .discharging: "arrow.down.circle"
        default: "battery.\(percent >= 88 ? 100 : percent >= 63 ? 75 : percent >= 38 ? 50 : percent >= 13 ? 25 : 0)percent"
        }
        let text = Preferences.bool(.showPercent) && model.battery != nil ? " \(percent)%" : ""
        // The menu bar redraws only when something visible changed.
        guard lastTitle?.symbol != symbol || lastTitle?.text != text, let button = statusItem?.button else { return }
        lastTitle = (symbol, text)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "chargnr")
        button.image?.isTemplate = true
        button.title = text
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit chargnr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem?.menu = menu
            button.performClick(nil)
            statusItem?.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            startLiveUpdates()
        }
    }

    /// Faster refresh only while the popover is open, for the live power readout.
    private func startLiveUpdates() {
        Task { await model.refresh() }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { await self?.model.refresh() }
        }
    }

    private func stopLiveUpdates() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    private func listenForPowerChanges() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { _ = Task { await delegate.model.refresh() } }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    // MARK: - Settings

    @objc private func openSettingsAction() { openSettings() }

    private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(
                model: model, onDisplayChange: { [weak self] in
                    guard let self else { return }
                    self.lastTitle = nil
                    self.updateStatusItem(self.model)
                })))
            window.title = "chargnr Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Snapshot (development)

    /// `chargnr.app/Contents/MacOS/chargnr --snapshot out.png` renders the
    /// popover and settings with live data to PNGs and quits, so the UI can be
    /// checked without screenshots of the real screen.
    private func snapshotPath() -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func snapshot(to path: String) async {
        await model.refresh()
        render(PopoverView(model: model), to: path)
        render(SettingsView(model: model), to: path.replacingOccurrences(of: ".png", with: "-settings.png"))
        NSApp.terminate(nil)
    }

    private func render(_ view: some View, to path: String) {
        // Popovers and windows draw their own background; a bare snapshot has none.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        window.appearance = appearance
        host.appearance = appearance
        window.contentView = host
        window.backgroundColor = .windowBackgroundColor
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
