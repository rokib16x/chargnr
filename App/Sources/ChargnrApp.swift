import AppKit
import ChargnrCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "bolt.batteryblock", accessibilityDescription: "chargnr")
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu()
    }

    // Rebuilt only when opened, so the menu costs nothing while closed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(withTitle: "chargnr \(Chargnr.version)", action: nil, keyEquivalent: "")
        if let battery = BatteryInfo.current() {
            menu.addItem(withTitle: "Battery \(battery.percent)%" + (battery.isCharging ? ", charging" : ""),
                         action: nil, keyEquivalent: "")
        }
        if let native = NativeChargeLimit.read(), native.enabled {
            menu.addItem(withTitle: "macOS limit \(native.limit)%", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: HelperInstaller.statusText, action: nil, keyEquivalent: "")
        if HelperInstaller.isEnabled {
            menu.addItem(withTitle: "Remove Helper", action: #selector(removeHelper), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Install Helper…", action: #selector(installHelper), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit chargnr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = item.action == #selector(NSApplication.terminate(_:)) ? nil : self }
    }

    @objc private func installHelper() {
        HelperInstaller.install()
    }

    @objc private func removeHelper() {
        Task { await HelperInstaller.uninstall() }
    }
}
