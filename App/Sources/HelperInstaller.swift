import AppKit
import ChargnrCore
import ServiceManagement

/// Registers the embedded helper with launchd through SMAppService. macOS asks
/// the user to approve it once in System Settings › General › Login Items.
@MainActor
enum HelperInstaller {
    static let service = SMAppService.daemon(plistName: HelperService.plistName)

    static var statusText: String {
        switch service.status {
        case .enabled: "Helper installed"
        case .requiresApproval: "Helper waiting for approval in Login Items"
        case .notRegistered: "Helper not installed"
        case .notFound: "Helper missing from the app bundle"
        @unknown default: "Helper status unknown"
        }
    }

    static var isEnabled: Bool { service.status == .enabled }

    static func install() {
        if Installer.isInstalled {
            alert("A command-line install of the helper is active.",
                  "Remove it first with: sudo chargnr uninstall")
            return
        }
        do {
            try service.register()
        } catch {
            // Registration throws "Operation not permitted" until approved.
            if service.status != .requiresApproval {
                alert("Could not install the helper.", error.localizedDescription)
                return
            }
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    static func uninstall() async {
        // Put charging back to normal before the helper goes away.
        try? await HelperClient().restoreNormal()
        do { try await service.unregister() } catch {
            alert("Could not remove the helper.", error.localizedDescription)
        }
    }

    private static func alert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
