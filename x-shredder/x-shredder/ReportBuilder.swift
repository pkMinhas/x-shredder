import Foundation
import Report

enum ReportBuilder {
    static let keychainService = "com.withpreet.x-shredder"

    /// Maps the helper's result onto the report fields.
    static func report(from result: EraseResult) -> EraseReport {
        EraseReport(
            toolVersion: result.helperVersion,
            startedAt: result.startedAt,
            finishedAt: result.finishedAt,
            deviceModel: result.deviceModel,
            deviceSizeBytes: result.deviceSizeBytes,
            serialNumber: result.serialNumber,
            passes: result.passes,
            passesVerified: result.passesVerified,
            verification: VerificationResult(rawValue: result.verification) ?? .notCompleted,
            succeeded: result.succeeded,
            errors: result.errors
        )
    }

    static func signedReport(from result: EraseResult, keyStore: SigningKeyStore) throws -> SignedReport {
        try ReportSigner.sign(report(from: result), with: keyStore.signingKey())
    }
}
