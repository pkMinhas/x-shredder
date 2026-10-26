import Foundation

/// Fixed wording used in the UI and in every report. Kept in one place so it
/// can be reviewed and approved as a unit.
public enum ReportWording {
    /// The tool performs a NIST 800-88 "Clear". It never claims "Purge".
    public static let methodLabelVerified = "Clear via overwrite, verified"
    public static let methodLabelNotVerified = "Clear via overwrite, not verified"

    public static let limitsStatement =
        "Overwrite cannot reach remapped or spare blocks. "
        + "Physical destruction is recommended for high-sensitivity data."
}

public enum VerificationResult: String, Codable, Sendable {
    case passed
    case failed
    case notCompleted
}

/// The contents of an erase certificate.
public struct EraseReport: Codable, Equatable, Sendable {
    public var toolVersion: String
    public var startedAt: Date
    public var finishedAt: Date
    public var deviceModel: String
    public var deviceSizeBytes: UInt64
    /// `nil` when the reader does not expose one.
    public var serialNumber: String?
    /// One entry per pass, in order, for example "random" then "zero".
    public var passes: [String]
    public var passesVerified: Int
    public var verification: VerificationResult
    public var succeeded: Bool
    public var errors: [String]
    public var methodLabel: String
    public var limitsStatement: String

    public init(
        toolVersion: String,
        startedAt: Date,
        finishedAt: Date,
        deviceModel: String,
        deviceSizeBytes: UInt64,
        serialNumber: String?,
        passes: [String],
        passesVerified: Int,
        verification: VerificationResult,
        succeeded: Bool,
        errors: [String]
    ) {
        self.toolVersion = toolVersion
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.deviceModel = deviceModel
        self.deviceSizeBytes = deviceSizeBytes
        self.serialNumber = serialNumber
        self.passes = passes
        self.passesVerified = passesVerified
        self.verification = verification
        self.succeeded = succeeded
        self.errors = errors
        // The "verified" label is only ever attached to a run that succeeded
        // with verification passed.
        self.methodLabel = succeeded && verification == .passed
            ? ReportWording.methodLabelVerified
            : ReportWording.methodLabelNotVerified
        self.limitsStatement = ReportWording.limitsStatement
    }
}
