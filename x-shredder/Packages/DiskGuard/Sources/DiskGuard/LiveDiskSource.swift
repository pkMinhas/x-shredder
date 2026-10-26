import Foundation
import DiskArbitration
import IOKit

/// One consistent reading of the system's disks.
public struct DiskSnapshot: Sendable {
    public var disks: [DiskDescription]
    public var context: SystemContext
    public var nodes: [MediaNode]
    public var mounts: [Mount]

    public func disk(named bsdName: String) -> DiskDescription? {
        disks.first { $0.bsdName == bsdName }
    }
}

/// Reads fresh disk data from DiskArbitration and IOKit. Read-only: nothing
/// in this type opens, mounts or unmounts a device.
public struct LiveDiskSource: Sendable {
    public init() {}

    /// Describes every whole disk and resolves the protected (boot) disks.
    public func snapshot() -> DiskSnapshot {
        let media = Registry.allMedia()
        let nodes = media.map(\.node)
        let mounts = Self.mounts()
        let protected = BootDiskResolver.protectedWholeDisks(mounts: mounts, nodes: nodes)

        var disks: [DiskDescription] = []
        if let session = DASessionCreate(kCFAllocatorDefault) {
            for entry in media where entry.node.isWhole {
                let name = entry.node.bsdName
                guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name),
                      let description = DADiskCopyDescription(disk) as? [String: Any]
                else {
                    // Listed with no readable description: every rule fails.
                    disks.append(DiskDescription(bsdName: name))
                    continue
                }
                var facts = entry.facts
                facts.volumeNames = Self.volumeNames(for: entry.descendantNames, session: session)
                disks.append(DiskDescription(bsdName: name, daDescription: description, registry: facts))
            }
        }
        disks.sort { Self.unit($0.bsdName) < Self.unit($1.bsdName) }
        return DiskSnapshot(
            disks: disks,
            context: SystemContext(protectedWholeDisks: protected),
            nodes: nodes,
            mounts: mounts
        )
    }

    private static func unit(_ bsdName: String) -> Int {
        Int(bsdName.dropFirst(4)) ?? Int.max
    }

    private static func volumeNames(for bsdNames: [String], session: DASession) -> [String] {
        var names: [String] = []
        for bsdName in bsdNames {
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
                  let description = DADiskCopyDescription(disk) as? [String: Any],
                  let volume = description["DAVolumeName"] as? String,
                  !names.contains(volume)
            else { continue }
            names.append(volume)
        }
        return names
    }

    static func mounts() -> [Mount] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        return (0..<Int(count)).map { index in
            var entry = buffer[index]
            let device = withUnsafePointer(to: &entry.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let mountPoint = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            return Mount(device: device, mountPoint: mountPoint)
        }
    }
}

/// IORegistry reads. Any failed call leaves the matching fact `nil`.
enum Registry {
    struct MediaEntry {
        var node: MediaNode
        var facts: RegistryFacts
        var descendantNames: [String]
    }

    private static let maxDepth = 64

    static func allMedia() -> [MediaEntry] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var entries: [MediaEntry] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let name = stringProperty(service, "BSD Name") else { continue }
            let isWhole = boolProperty(service, "Whole") ?? false

            var ancestorClasses: [String]? = []
            var parentMedia: [String]? = []
            collectAncestors(of: service, depth: 0, classes: &ancestorClasses, nearestMedia: &parentMedia, belowMedia: false)

            var roles: [String]? = []
            var descendants: [String] = []
            collectDescendants(of: service, depth: 0, roles: &roles, names: &descendants)

            var entryID: UInt64 = 0
            let hasID = IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS

            let facts = RegistryFacts(
                registryEntryID: hasID ? entryID : nil,
                serialNumber: serialNumber(of: service),
                ancestorClasses: ancestorClasses,
                hasMediaAncestor: parentMedia.map { !$0.isEmpty },
                descendantVolumeRoles: roles
            )
            // An unreadable parent chain is recorded as "no parents". The
            // resolver then cannot reach a whole disk through it and fails
            // closed.
            let node = MediaNode(bsdName: name, isWhole: isWhole, parents: parentMedia ?? [])
            entries.append(MediaEntry(node: node, facts: facts, descendantNames: descendants))
        }
        return entries
    }

    private static func collectAncestors(
        of entry: io_registry_entry_t,
        depth: Int,
        classes: inout [String]?,
        nearestMedia: inout [String]?,
        belowMedia: Bool
    ) {
        guard depth < maxDepth else { classes = nil; nearestMedia = nil; return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            classes = nil
            nearestMedia = nil
            return
        }
        defer { IOObjectRelease(iterator) }
        while case let parent = IOIteratorNext(iterator), parent != 0 {
            defer { IOObjectRelease(parent) }
            guard let name = className(parent) else { classes = nil; continue }
            if classes?.contains(name) == false { classes?.append(name) }
            var isBelowMedia = belowMedia
            if IOObjectConformsTo(parent, "IOMedia") != 0 {
                if !belowMedia {
                    if let bsd = stringProperty(parent, "BSD Name") {
                        if nearestMedia?.contains(bsd) == false { nearestMedia?.append(bsd) }
                    } else {
                        nearestMedia = nil
                    }
                }
                isBelowMedia = true
            }
            collectAncestors(of: parent, depth: depth + 1, classes: &classes, nearestMedia: &nearestMedia, belowMedia: isBelowMedia)
        }
    }

    private static func collectDescendants(
        of entry: io_registry_entry_t,
        depth: Int,
        roles: inout [String]?,
        names: inout [String]
    ) {
        guard depth < maxDepth else { roles = nil; return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            roles = nil
            return
        }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOMedia") != 0 {
                if let bsd = stringProperty(child, "BSD Name") { names.append(bsd) }
                if let property = IORegistryEntryCreateCFProperty(child, "Role" as CFString, kCFAllocatorDefault, 0) {
                    if let list = property.takeRetainedValue() as? [String] {
                        for role in list where roles?.contains(role) == false { roles?.append(role) }
                    } else {
                        roles = nil
                    }
                }
            }
            collectDescendants(of: child, depth: depth + 1, roles: &roles, names: &names)
        }
    }

    private static func serialNumber(of entry: io_registry_entry_t) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        for key in ["USB Serial Number", "kUSBSerialNumberString", "Serial Number"] {
            if let value = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault, options) as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func className(_ entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buffer) == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private static func boolProperty(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
        (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.boolValue
    }
}
