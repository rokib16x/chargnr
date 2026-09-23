import AppKit
import ChargnrCore
import ServiceManagement

/// Installs the helper. Team-signed builds register the embedded daemon with
/// SMAppService (approved once in Login Items). Ad-hoc builds cannot, so they
/// run the embedded CLI's `install` with an administrator password prompt.
@MainActor
enum HelperInstaller {
    static let service = SMAppService.daemon(plistName: HelperService.plistName)

    static var isEnabled: Bool { service.status == .enabled }
    static var needsApproval: Bool { service.status == .requiresApproval }

    /// SMAppService needs a real signature; ad-hoc builds use the password route.
    static var usesServiceManagement: Bool { CallerPolicy.ownTeamID() != nil }

    /// The CLI inside the app bundle.
    static var embeddedCLI: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/chargnr-cli")
    }

    enum Failure: Error, CustomStringConvertible {
        case cliInstallActive
        case cancelled
        case failed(String)

        var description: String {
            switch self {
            case .cliInstallActive: "A command-line install of the helper is active. Remove it with: sudo chargnr uninstall"
            case .cancelled: "Installation cancelled."
            case .failed(let message): message
            }
        }
    }

    static func install() async throws(Failure) {
        if usesServiceManagement {
            if Installer.isInstalled { throw .cliInstallActive }
            do { try service.register() } catch {
                // Throws until the user approves it in Login Items.
                if service.status != .requiresApproval { throw .failed(error.localizedDescription) }
            }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } else {
            try await runAsAdmin("install")
        }
    }

    static func uninstall() async throws(Failure) {
        // Put charging back to normal before the helper goes away.
        try? await HelperClient().restoreNormal()
        if isEnabled {
            do { try await service.unregister() } catch { throw .failed(error.localizedDescription) }
        } else if Installer.isInstalled {
            try await runAsAdmin("uninstall")
        }
    }

    /// Runs the embedded CLI as root through macOS's standard password dialog.
    /// The path goes through AppleScript's `quoted form of`, so no part of it
    /// is ever interpreted by the shell.
    private static func runAsAdmin(_ command: String) async throws(Failure) {
        let cli = embeddedCLI.path
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            throw .failed("The chargnr command-line tool is missing from the app bundle.")
        }
        let escaped = cli.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script (quoted form of \"\(escaped)\") & \" \(command)\" with administrator privileges"

        // NSAppleScript must run on the main thread; the password dialog is modal anyway.
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw .cancelled }
        throw .failed(error[NSAppleScript.errorMessage] as? String ?? "The helper could not be installed.")
    }
}
