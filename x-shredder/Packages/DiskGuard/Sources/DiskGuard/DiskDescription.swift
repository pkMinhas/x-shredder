import Foundation

/// Everything DiskGuard knows about one disk.
///
/// Every safety-relevant field is optional. `nil` means "could not be read",
/// and the rules treat that as a failure (fail closed).
public struct DiskDescription: Codable, Equatable, Sendable {
    public var bsdName: String

    // DiskArbitration description
    public var isWhole: Bool?
    public var isInternal: Bool?
    public var protocolName: String?
    public var isRemovable: Bool?
    public var isEjectable: Bool?
    public var isWritable: Bool?
    public var mediaSize: UInt64?
    public var blockSize: UInt32?
    public var bsdMajor: Int32?
    public var bsdMinor: Int32?
    public var mediaName: String?
    public var deviceModel: String?
    public var deviceVendor: String?
    public var busName: String?

    // IOKit
    public var registryEntryID: UInt64?
    public var serialNumber: String?
    /// Class names of every IOService-plane ancestor of the media object.
    public var ancestorClasses: [String]?
    /// True when another IOMedia sits above this one (APFS synthesized
    /// containers, CoreStorage and RAID volumes).
    public var hasMediaAncestor: Bool?
    /// APFS volume roles found on any volume stored on this disk.
    public var descendantVolumeRoles: [String]?

    /// Display only. Never used by a rule.
    public var volumeNames: [String]

    public init(bsdName: String) {
        self.bsdName = bsdName
        self.volumeNames = []
    }
}

/// Facts read from the IORegistry for one media object.
public struct RegistryFacts: Equatable, Sendable {
    public var registryEntryID: UInt64?
    public var serialNumber: String?
    public var ancestorClasses: [String]?
    public var hasMediaAncestor: Bool?
    public var descendantVolumeRoles: [String]?
    public var volumeNames: [String]

    public init(
        registryEntryID: UInt64? = nil,
        serialNumber: String? = nil,
        ancestorClasses: [String]? = nil,
        hasMediaAncestor: Bool? = nil,
        descendantVolumeRoles: [String]? = nil,
        volumeNames: [String] = []
    ) {
        self.registryEntryID = registryEntryID
        self.serialNumber = serialNumber
        self.ancestorClasses = ancestorClasses
        self.hasMediaAncestor = hasMediaAncestor
        self.descendantVolumeRoles = descendantVolumeRoles
        self.volumeNames = volumeNames
    }
}

extension DiskDescription {
    /// Builds a description from a DiskArbitration description dictionary and
    /// the IORegistry facts. Pure, so it can be tested with recorded input.
    public init(bsdName: String, daDescription: [String: Any], registry: RegistryFacts) {
        self.init(bsdName: bsdName)

        func bool(_ key: String) -> Bool? { (daDescription[key] as? NSNumber)?.boolValue }
        func string(_ key: String) -> String? { daDescription[key] as? String }
        func number(_ key: String) -> NSNumber? { daDescription[key] as? NSNumber }

        isWhole = bool("DAMediaWhole")
        isInternal = bool("DADeviceInternal")
        protocolName = string("DADeviceProtocol")
        isRemovable = bool("DAMediaRemovable")
        isEjectable = bool("DAMediaEjectable")
        isWritable = bool("DAMediaWritable")
        mediaSize = number("DAMediaSize")?.uint64Value
        blockSize = number("DAMediaBlockSize")?.uint32Value
        bsdMajor = number("DAMediaBSDMajor")?.int32Value
        bsdMinor = number("DAMediaBSDMinor")?.int32Value
        mediaName = string("DAMediaName")
        deviceModel = string("DADeviceModel")
        deviceVendor = string("DADeviceVendor")
        busName = string("DABusName")

        registryEntryID = registry.registryEntryID
        serialNumber = registry.serialNumber
        ancestorClasses = registry.ancestorClasses
        hasMediaAncestor = registry.hasMediaAncestor
        descendantVolumeRoles = registry.descendantVolumeRoles
        volumeNames = registry.volumeNames
    }

    /// Vendor and model, falling back to the media name, then the BSD name.
    public var displayName: String {
        let parts = [deviceVendor, deviceModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if let media = mediaName?.trimmingCharacters(in: .whitespacesAndNewlines), !media.isEmpty {
            return media
        }
        return bsdName
    }

    /// Size as shown in the UI and typed in the confirmation step.
    public var sizeLabel: String {
        guard let mediaSize else { return "Unknown size" }
        return SizeFormat.label(bytes: mediaSize)
    }
}

public enum SizeFormat {
    /// Decimal units with one decimal place, independent of the user's locale
    /// so the confirmation phrase is stable.
    public static func label(bytes: UInt64) -> String {
        let value = Double(bytes)
        let (scaled, unit): (Double, String)
        switch value {
        case ..<1_000_000: (scaled, unit) = (value / 1_000, "KB")
        case ..<1_000_000_000: (scaled, unit) = (value / 1_000_000, "MB")
        case ..<1_000_000_000_000: (scaled, unit) = (value / 1_000_000_000, "GB")
        default: (scaled, unit) = (value / 1_000_000_000_000, "TB")
        }
        return String(format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), scaled, unit)
    }
}
