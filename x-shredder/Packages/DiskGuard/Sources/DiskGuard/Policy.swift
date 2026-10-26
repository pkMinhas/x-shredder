import Foundation

/// The tunable part of the eligibility rules. There is deliberately no way to
/// switch a rule off.
public struct Policy: Equatable, Sendable {
    /// Rule 6. Anything not listed here is refused.
    public var allowedProtocols: Set<String>
    /// Rule 7.
    public var maxSizeBytes: UInt64
    /// Rule 2 exception. The Mac's built-in SD card slot reports as internal.
    /// When true, a disk identified as that slot (see
    /// `Rules.isBuiltInSDSlot`) passes rule 2. Every other rule still applies.
    public var allowBuiltInSDSlot: Bool

    #if DEBUG
    /// Debug builds only. Lets small disk images through so the erase path can
    /// be exercised without real hardware. Compiled out of release builds;
    /// scripts/check-release-flags.sh looks for `testDiskImageMarker` in
    /// release binaries.
    public var allowTestDiskImages = false
    public var maxTestDiskImageBytes: UInt64 = 256 * 1024 * 1024
    public static let testDiskImageMarker = "XSHREDDER-TEST-DISK-IMAGES-ENABLED"
    #endif

    public init(allowedProtocols: Set<String>, maxSizeBytes: UInt64, allowBuiltInSDSlot: Bool = false) {
        self.allowedProtocols = allowedProtocols
        self.maxSizeBytes = maxSizeBytes
        self.allowBuiltInSDSlot = allowBuiltInSDSlot
    }

    /// USB and Secure Digital, 2 TB cap. The built-in SD slot is allowed
    /// (relaxed policy).
    public static let standard = Policy(
        allowedProtocols: ["USB", "Secure Digital"],
        maxSizeBytes: 2_000_000_000_000,
        allowBuiltInSDSlot: true
    )
}
