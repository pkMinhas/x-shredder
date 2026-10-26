import Foundation

/// Identity of a disk at validation time. Compared again after the device is
/// opened, to catch a different disk taking the same BSD name.
public struct DiskFingerprint: Codable, Equatable, Sendable {
    public let registryEntryID: UInt64
    public let mediaSize: UInt64
    public let blockSize: UInt32
    public let protocolName: String

    public init(registryEntryID: UInt64, mediaSize: UInt64, blockSize: UInt32, protocolName: String) {
        self.registryEntryID = registryEntryID
        self.mediaSize = mediaSize
        self.blockSize = blockSize
        self.protocolName = protocolName
    }

    /// Fails when any part of the identity is unreadable.
    public init?(_ disk: DiskDescription) {
        guard let registryEntryID = disk.registryEntryID,
              let mediaSize = disk.mediaSize,
              let blockSize = disk.blockSize,
              let protocolName = disk.protocolName
        else { return nil }
        self.init(
            registryEntryID: registryEntryID,
            mediaSize: mediaSize,
            blockSize: blockSize,
            protocolName: protocolName
        )
    }

    /// Names the first field that differs, or `nil` when identical.
    public func difference(from other: DiskFingerprint) -> String? {
        if registryEntryID != other.registryEntryID { return "registry entry ID" }
        if mediaSize != other.mediaSize { return "size" }
        if blockSize != other.blockSize { return "block size" }
        if protocolName != other.protocolName { return "protocol" }
        return nil
    }

    /// Checks the geometry read from the open file descriptor.
    public func matchesGeometry(blockSize: Int, blockCount: UInt64) -> Bool {
        guard blockSize > 0, UInt32(exactly: blockSize) == self.blockSize else { return false }
        let (bytes, overflow) = blockCount.multipliedReportingOverflow(by: UInt64(blockSize))
        return !overflow && bytes == mediaSize
    }
}
