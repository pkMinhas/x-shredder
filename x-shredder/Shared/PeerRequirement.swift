import Foundation
import Security

/// Code-signing requirements for the two ends of the XPC connection.
///
/// Each side requires the other to have the expected bundle identifier and to
/// be signed by the same team as itself. The team ID is read from the running
/// binary's own signature, so it is never hard-coded.
enum PeerRequirement {
    /// The team identifier in this process's code signature. `nil` for
    /// unsigned and ad-hoc signed builds.
    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        else { return nil }
        return isPlainIdentifier(team) ? team : nil
    }

    /// A requirement string pinning `identifier` and this process's team.
    /// `nil` when this process has no team identifier: there is then nothing
    /// to pin, and callers must refuse to connect.
    static func requirement(forIdentifier identifier: String) -> String? {
        guard let team = ownTeamIdentifier() else { return nil }
        return requirement(forIdentifier: identifier, team: team)
    }

    static func requirement(forIdentifier identifier: String, team: String) -> String? {
        guard isPlainIdentifier(team), identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    private static func isPlainIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
