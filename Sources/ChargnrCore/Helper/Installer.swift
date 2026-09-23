import Foundation

/// Installs the helper as a LaunchDaemon for CLI-only setups (Homebrew
/// formula, built from source). The app uses SMAppService instead.
public enum Installer {
    public static let helperPath = "/Library/PrivilegedHelperTools/\(Chargnr.helperID)"
    public static let plistPath = "/Library/LaunchDaemons/\(HelperService.plistName)"

    public enum Failure: Error, CustomStringConvertible {
        case needsRoot
        case helperNotFound(String)
        case step(String)

        public var description: String {
            switch self {
            case .needsRoot: "installing the helper needs root: run it with sudo"
            case .helperNotFound(let path): "chargnr-helper not found at \(path)"
            case .step(let message): message
            }
        }
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// The launchd job, as a property list.
    public static func plist() -> [String: Any] {
        [
            "Label": HelperService.name,
            "ProgramArguments": [helperPath],
            "MachServices": [HelperService.name: true],
            "RunAtLoad": true,
            "KeepAlive": true,
            // Low priority work; macOS may delay it to save power.
            "ProcessType": "Background",
        ]
    }

    /// Copies `helper` to a root-owned location (a root daemon must never run
    /// a file its user can edit), writes the plist and starts the job.
    public static func install(helper source: String) throws(Failure) {
        guard getuid() == 0 else { throw .needsRoot }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: source) else { throw .helperNotFound(source) }

        if isInstalled { launchctl("bootout", "system/\(HelperService.name)") }
        do {
            try fm.createDirectory(atPath: (helperPath as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: helperPath) { try fm.removeItem(atPath: helperPath) }
            try fm.copyItem(atPath: source, toPath: helperPath)
            try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755],
                                 ofItemAtPath: helperPath)
            let data = try PropertyListSerialization.data(fromPropertyList: plist(), format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o644],
                                 ofItemAtPath: plistPath)
        } catch {
            throw .step("could not install the helper: \(error.localizedDescription)")
        }
        guard launchctl("bootstrap", "system", plistPath) == 0 else {
            throw .step("launchctl could not start the helper (see `log show --predicate 'subsystem == \"\(Chargnr.helperID)\"'`)")
        }
    }

    /// Stops the job (the helper restores normal charging on SIGTERM) and removes its files.
    public static func uninstall() throws(Failure) {
        guard getuid() == 0 else { throw .needsRoot }
        launchctl("bootout", "system/\(HelperService.name)")
        for path in [plistPath, helperPath] where FileManager.default.fileExists(atPath: path) {
            do { try FileManager.default.removeItem(atPath: path) } catch {
                throw .step("could not remove \(path): \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private static func launchctl(_ args: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
