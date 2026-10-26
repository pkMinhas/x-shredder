import Foundation

/// The eight eligibility rules. A disk is selectable only if every one passes.
public enum Rule: String, Codable, CaseIterable, Sendable {
    case wholeDisk
    case notInternal
    case notVirtual
    case notBootOrSystem
    case removable
    case protocolAllowed
    case sizeCap
    case writable
}

public struct RuleFailure: Codable, Equatable, Sendable {
    public let rule: Rule
    public let reason: String

    public init(rule: Rule, reason: String) {
        self.rule = rule
        self.reason = reason
    }
}

public enum Eligibility: Equatable, Sendable {
    case eligible
    case ineligible([RuleFailure])

    public var isEligible: Bool { self == .eligible }

    public var failures: [RuleFailure] {
        if case .ineligible(let failures) = self { return failures }
        return []
    }
}

/// System facts that are not properties of a single disk.
public struct SystemContext: Equatable, Sendable {
    /// Whole disks that hold the running system. `nil` means the boot disk
    /// could not be resolved, which fails rule 4 for every disk.
    public var protectedWholeDisks: Set<String>?

    public init(protectedWholeDisks: Set<String>?) {
        self.protectedWholeDisks = protectedWholeDisks
    }
}

public enum Rules {
    /// APFS roles that mark a system volume group. A disk storing any of
    /// these is refused even when it is not the running system.
    static let systemVolumeRoles: Set<String> = [
        "System", "Data", "Preboot", "Recovery", "VM",
        "Update", "xART", "Hardware", "Installer", "Prelogin",
    ]

    /// IOKit class name prefixes that identify virtual or layered storage.
    static let virtualClassPrefixes = [
        "IOHDIX", "AppleDiskImage", "IODiskImage", "AppleAPFS",
        "CoreStorage", "AppleRAID", "AppleVirtIO",
    ]

    // MARK: Rule 1

    public static func wholeDisk(_ d: DiskDescription) -> RuleFailure? {
        guard BSDName.isWholeDiskName(d.bsdName) else {
            return RuleFailure(rule: .wholeDisk, reason: "Not a whole-disk name")
        }
        guard let isWhole = d.isWhole else {
            return RuleFailure(rule: .wholeDisk, reason: "Could not tell if this is a whole disk")
        }
        return isWhole ? nil : RuleFailure(rule: .wholeDisk, reason: "Partition, not a whole disk")
    }

    // MARK: Rule 2

    public static func notInternal(_ d: DiskDescription, policy: Policy) -> RuleFailure? {
        guard let isInternal = d.isInternal else {
            #if DEBUG
            if isAllowedTestDiskImage(d, policy: policy) { return nil }
            #endif
            return RuleFailure(rule: .notInternal, reason: "Could not tell if the disk is internal")
        }
        return isInternal ? RuleFailure(rule: .notInternal, reason: "Internal disk") : nil
    }

    // MARK: Rule 3

    public static func notVirtual(_ d: DiskDescription, policy: Policy) -> RuleFailure? {
        guard let protocolName = d.protocolName,
              let hasMediaAncestor = d.hasMediaAncestor,
              let ancestors = d.ancestorClasses
        else {
            return RuleFailure(rule: .notVirtual, reason: "Could not tell if the disk is virtual")
        }
        if hasMediaAncestor {
            return RuleFailure(rule: .notVirtual, reason: "Synthesized or layered disk")
        }
        #if DEBUG
        if isAllowedTestDiskImage(d, policy: policy) { return nil }
        #endif
        if protocolName == "Virtual Interface" || d.deviceModel == "Disk Image" {
            return RuleFailure(rule: .notVirtual, reason: "Disk image or virtual disk")
        }
        if ancestors.contains(where: isVirtualClass) {
            return RuleFailure(rule: .notVirtual, reason: "Disk image or virtual disk")
        }
        return nil
    }

    // MARK: Rule 4

    public static func notBootOrSystem(_ d: DiskDescription, context: SystemContext) -> RuleFailure? {
        guard let protected = context.protectedWholeDisks else {
            return RuleFailure(rule: .notBootOrSystem, reason: "Could not resolve the boot disk")
        }
        if protected.contains(d.bsdName) {
            return RuleFailure(rule: .notBootOrSystem, reason: "Holds the running system")
        }
        guard let roles = d.descendantVolumeRoles else {
            return RuleFailure(rule: .notBootOrSystem, reason: "Could not read the volumes on this disk")
        }
        if roles.contains(where: systemVolumeRoles.contains) {
            return RuleFailure(rule: .notBootOrSystem, reason: "Holds system volumes")
        }
        return nil
    }

    // MARK: Rule 5

    public static func removable(_ d: DiskDescription) -> RuleFailure? {
        if d.isRemovable == true || d.isEjectable == true { return nil }
        if d.isRemovable == nil && d.isEjectable == nil {
            return RuleFailure(rule: .removable, reason: "Could not tell if the media is removable")
        }
        return RuleFailure(rule: .removable, reason: "Media is not removable or ejectable")
    }

    // MARK: Rule 6

    public static func protocolAllowed(_ d: DiskDescription, policy: Policy) -> RuleFailure? {
        guard let protocolName = d.protocolName else {
            return RuleFailure(rule: .protocolAllowed, reason: "Unknown connection type")
        }
        if policy.allowedProtocols.contains(protocolName) { return nil }
        #if DEBUG
        if isAllowedTestDiskImage(d, policy: policy) { return nil }
        #endif
        return RuleFailure(rule: .protocolAllowed, reason: "Connection type \"\(protocolName)\" is not allowed")
    }

    // MARK: Rule 7

    public static func sizeCap(_ d: DiskDescription, policy: Policy) -> RuleFailure? {
        guard let size = d.mediaSize, let blockSize = d.blockSize else {
            return RuleFailure(rule: .sizeCap, reason: "Could not read the disk size")
        }
        guard size > 0, blockSize > 0, size % UInt64(blockSize) == 0 else {
            return RuleFailure(rule: .sizeCap, reason: "Disk reports an invalid size")
        }
        if size > policy.maxSizeBytes {
            return RuleFailure(
                rule: .sizeCap,
                reason: "Larger than the \(SizeFormat.label(bytes: policy.maxSizeBytes)) limit"
            )
        }
        return nil
    }

    // MARK: Rule 8

    public static func writable(_ d: DiskDescription) -> RuleFailure? {
        guard let isWritable = d.isWritable else {
            return RuleFailure(rule: .writable, reason: "Could not tell if the media is writable")
        }
        return isWritable ? nil : RuleFailure(rule: .writable, reason: "Read-only or write-protected")
    }

    // MARK: Helpers

    static func isVirtualClass(_ name: String) -> Bool {
        virtualClassPrefixes.contains(where: name.hasPrefix)
    }

    #if DEBUG
    /// Debug builds only: a small, plain disk image and nothing else.
    static func isAllowedTestDiskImage(_ d: DiskDescription, policy: Policy) -> Bool {
        guard policy.allowTestDiskImages,
              d.protocolName == "Virtual Interface",
              d.deviceModel == "Disk Image",
              d.hasMediaAncestor == false,
              let ancestors = d.ancestorClasses,
              ancestors.contains(where: { $0.hasPrefix("IOHDIX") || $0.hasPrefix("AppleDiskImage") }),
              !ancestors.contains(where: { $0.hasPrefix("AppleAPFS") }),
              let size = d.mediaSize, size <= policy.maxTestDiskImageBytes
        else { return false }
        return true
    }
    #endif
}

public enum BSDName {
    /// `disk` followed by digits. No slices, no paths.
    public static func isWholeDiskName(_ name: String) -> Bool {
        guard name.hasPrefix("disk") else { return false }
        let digits = name.dropFirst(4)
        return !digits.isEmpty && digits.count <= 5 && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

public enum DiskGuard {
    /// Runs every rule. This is the only function that decides whether a disk
    /// may be selected or erased.
    public static func evaluate(
        _ disk: DiskDescription,
        context: SystemContext,
        policy: Policy
    ) -> Eligibility {
        let failures = [
            Rules.wholeDisk(disk),
            Rules.notInternal(disk, policy: policy),
            Rules.notVirtual(disk, policy: policy),
            Rules.notBootOrSystem(disk, context: context),
            Rules.removable(disk),
            Rules.protocolAllowed(disk, policy: policy),
            Rules.sizeCap(disk, policy: policy),
            Rules.writable(disk),
        ].compactMap { $0 }
        return failures.isEmpty ? .eligible : .ineligible(failures)
    }
}
