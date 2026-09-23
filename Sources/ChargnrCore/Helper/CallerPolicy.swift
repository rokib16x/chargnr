import Foundation
import Security

/// Who may talk to the helper.
///
/// - Signed with a Team ID (release builds): only chargnr's own app and CLI
///   signed by that same team. Checked by the kernel-backed audit token via
///   `setConnectionCodeSigningRequirement`, so a lookalike binary or a reused
///   PID cannot pass.
/// - Not team-signed (built from source, Homebrew formula): root, or the user
///   logged in at the console. There is no signature to check, and the XPC
///   interface only takes a validated config, so the most a local process of
///   that user can do is change the charge limit, which they could do anyway.
public enum CallerPolicy: Equatable, Sendable {
    case team(requirement: String)
    case consoleUser

    /// Derives the policy from the helper's own signature.
    public static func current() -> CallerPolicy {
        guard let team = ownTeamID() else { return .consoleUser }
        return .team(requirement: requirement(team: team))
    }

    /// True for root and for the user who owns the console right now.
    public static func isRootOrConsoleUser(_ uid: uid_t) -> Bool {
        if uid == 0 { return true }
        var info = stat()
        return stat("/dev/console", &info) == 0 && info.st_uid == uid
    }

    public static func requirement(team: String) -> String {
        let identifiers = HelperService.clientIdentifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(identifiers))"
    }

    /// The Team ID this process is signed with, or nil for ad-hoc / unsigned builds.
    public static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
