import Foundation
import CryptoKit

/// A report with an Ed25519 signature over its canonical JSON encoding.
public struct SignedReport: Codable, Equatable, Sendable {
    public static let algorithm = "Ed25519"

    public var report: EraseReport
    public var algorithm: String
    /// Raw 32-byte public key, base64.
    public var publicKey: String
    /// Signature over `ReportSigner.canonicalData(report)`, base64.
    public var signature: String

    /// Short form of the public key for display.
    public var publicKeyFingerprint: String {
        guard let data = Data(base64Encoded: publicKey) else { return "invalid" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

public enum ReportSigner {
    /// Sorted keys and ISO 8601 dates, so the same report always encodes to
    /// the same bytes.
    public static func canonicalData(_ report: EraseReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    public static func sign(_ report: EraseReport, with key: Curve25519.Signing.PrivateKey) throws -> SignedReport {
        let signature = try key.signature(for: canonicalData(report))
        return SignedReport(
            report: report,
            algorithm: SignedReport.algorithm,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            signature: signature.base64EncodedString()
        )
    }

    /// True when the signature matches the report and the embedded public
    /// key. This shows the report was not altered after signing. It does not
    /// by itself show who holds the key.
    public static func verify(_ signed: SignedReport) -> Bool {
        guard signed.algorithm == SignedReport.algorithm,
              let keyData = Data(base64Encoded: signed.publicKey),
              let signature = Data(base64Encoded: signed.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let data = try? canonicalData(signed.report)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

public protocol SigningKeyStore {
    /// Returns the stored signing key, creating one on first use.
    func signingKey() throws -> Curve25519.Signing.PrivateKey
}

public final class InMemorySigningKeyStore: SigningKeyStore {
    private let key = Curve25519.Signing.PrivateKey()

    public init() {}

    public func signingKey() throws -> Curve25519.Signing.PrivateKey { key }
}

/// Keeps the signing key in the user's login keychain.
public struct KeychainSigningKeyStore: SigningKeyStore {
    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    private let service: String
    private let account = "report-signing-ed25519"

    public init(service: String) {
        self.service = service
    }

    public func signingKey() throws -> Curve25519.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var item: CFTypeRef?
        let lookup = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }

        let key = Curve25519.Signing.PrivateKey()
        let attributes = query.merging([
            kSecValueData as String: key.rawRepresentation,
            kSecAttrLabel as String: "x-shredder report signing key",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]) { $1 }
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
        return key
    }
}
