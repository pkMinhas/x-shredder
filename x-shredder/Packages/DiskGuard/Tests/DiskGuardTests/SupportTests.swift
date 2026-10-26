import XCTest
@testable import DiskGuard

final class BootDiskResolverTests: XCTestCase {
    func testResolvesBootDiskThroughSnapshotVolumeContainerAndStore() throws {
        let topology = try Fixtures.topology("topology-apple-silicon")
        let protected = try XCTUnwrap(BootDiskResolver.protectedWholeDisks(mounts: topology.mounts, nodes: topology.nodes))
        XCTAssertTrue(protected.contains("disk0"), "physical boot disk")
        XCTAssertTrue(protected.contains("disk3"), "synthesized system container")
        XCTAssertTrue(protected.contains("disk1"), "iSC container mounted under /System/Volumes")
        XCTAssertFalse(protected.contains("disk18"))
    }

    func testWalk() {
        let nodes = [
            MediaNode(bsdName: "disk0", isWhole: true, parents: []),
            MediaNode(bsdName: "disk0s2", isWhole: false, parents: ["disk0"]),
            MediaNode(bsdName: "disk3", isWhole: true, parents: ["disk0s2"]),
            MediaNode(bsdName: "disk3s1", isWhole: false, parents: ["disk3"]),
            MediaNode(bsdName: "disk3s1s1", isWhole: false, parents: ["disk3s1"]),
            MediaNode(bsdName: "disk3s5", isWhole: false, parents: ["disk3"]),
            MediaNode(bsdName: "disk4", isWhole: true, parents: []),
            MediaNode(bsdName: "disk4s1", isWhole: false, parents: ["disk4"]),
        ]
        let mounts = [
            Mount(device: "/dev/disk3s1s1", mountPoint: "/"),
            Mount(device: "devfs", mountPoint: "/dev"),
            Mount(device: "/dev/disk3s5", mountPoint: "/System/Volumes/Data"),
            Mount(device: "/dev/disk4s1", mountPoint: "/Volumes/NO NAME"),
        ]
        XCTAssertEqual(BootDiskResolver.protectedWholeDisks(mounts: mounts, nodes: nodes), ["disk0", "disk3"])
    }

    func testFusionStyleContainerProtectsEveryPhysicalStore() {
        let nodes = [
            MediaNode(bsdName: "disk0", isWhole: true, parents: []),
            MediaNode(bsdName: "disk0s2", isWhole: false, parents: ["disk0"]),
            MediaNode(bsdName: "disk1", isWhole: true, parents: []),
            MediaNode(bsdName: "disk1s2", isWhole: false, parents: ["disk1"]),
            MediaNode(bsdName: "disk2", isWhole: true, parents: ["disk0s2", "disk1s2"]),
            MediaNode(bsdName: "disk2s1", isWhole: false, parents: ["disk2"]),
        ]
        let mounts = [Mount(device: "/dev/disk2s1", mountPoint: "/")]
        XCTAssertEqual(BootDiskResolver.protectedWholeDisks(mounts: mounts, nodes: nodes), ["disk0", "disk1", "disk2"])
    }

    func testFailsClosed() {
        let nodes = [
            MediaNode(bsdName: "disk0", isWhole: true, parents: []),
            MediaNode(bsdName: "disk0s2", isWhole: false, parents: ["disk0"]),
        ]
        // No root mount.
        XCTAssertNil(BootDiskResolver.protectedWholeDisks(mounts: [], nodes: nodes))
        XCTAssertNil(BootDiskResolver.protectedWholeDisks(
            mounts: [Mount(device: "/dev/disk0s2", mountPoint: "/System/Volumes/Data")], nodes: nodes))
        // Root device missing from the registry.
        XCTAssertNil(BootDiskResolver.protectedWholeDisks(
            mounts: [Mount(device: "/dev/disk9s1", mountPoint: "/")], nodes: nodes))
        // Broken chain above the root volume.
        XCTAssertNil(BootDiskResolver.protectedWholeDisks(
            mounts: [Mount(device: "/dev/disk3s1", mountPoint: "/")],
            nodes: nodes + [MediaNode(bsdName: "disk3s1", isWhole: false, parents: ["disk3"])]))
        // A chain that never reaches a whole disk.
        XCTAssertNil(BootDiskResolver.protectedWholeDisks(
            mounts: [Mount(device: "/dev/disk5s1", mountPoint: "/")],
            nodes: [MediaNode(bsdName: "disk5s1", isWhole: false, parents: [])]))
    }
}

final class FingerprintTests: XCTestCase {
    func testRequiresEveryField() throws {
        let disk = try Fixtures.eligibleCard().description
        XCTAssertNotNil(DiskFingerprint(disk))
        for mutate: (inout DiskDescription) -> Void in [
            { $0.registryEntryID = nil }, { $0.mediaSize = nil }, { $0.blockSize = nil }, { $0.protocolName = nil },
        ] {
            var copy = disk
            mutate(&copy)
            XCTAssertNil(DiskFingerprint(copy))
        }
    }

    func testDifference() throws {
        let disk = try Fixtures.eligibleCard().description
        let original = try XCTUnwrap(DiskFingerprint(disk))
        XCTAssertNil(original.difference(from: original))

        var swapped = disk
        swapped.registryEntryID = 4_295_999_999
        XCTAssertEqual(original.difference(from: try XCTUnwrap(DiskFingerprint(swapped))), "registry entry ID")
        var resized = disk
        resized.mediaSize = 64_000_000_000
        XCTAssertEqual(original.difference(from: try XCTUnwrap(DiskFingerprint(resized))), "size")
        var reblocked = disk
        reblocked.blockSize = 4096
        XCTAssertEqual(original.difference(from: try XCTUnwrap(DiskFingerprint(reblocked))), "block size")
        var rewired = disk
        rewired.protocolName = "Secure Digital"
        XCTAssertEqual(original.difference(from: try XCTUnwrap(DiskFingerprint(rewired))), "protocol")
    }

    func testGeometry() {
        let fingerprint = DiskFingerprint(registryEntryID: 1, mediaSize: 512 * 1000, blockSize: 512, protocolName: "USB")
        XCTAssertTrue(fingerprint.matchesGeometry(blockSize: 512, blockCount: 1000))
        XCTAssertFalse(fingerprint.matchesGeometry(blockSize: 512, blockCount: 999))
        XCTAssertFalse(fingerprint.matchesGeometry(blockSize: 4096, blockCount: 125))
        XCTAssertFalse(fingerprint.matchesGeometry(blockSize: 0, blockCount: 1000))
        XCTAssertFalse(fingerprint.matchesGeometry(blockSize: 512, blockCount: .max))
    }
}

final class InFlightCheckTests: XCTestCase {
    func testViolations() throws {
        let fixture = try Fixtures.eligibleCard()
        let disk = fixture.description
        let fingerprint = try XCTUnwrap(DiskFingerprint(disk))
        func check(_ disk: DiskDescription?, _ context: SystemContext? = nil) -> String? {
            InFlightCheck.violation(disk: disk, context: context ?? fixture.context, fingerprint: fingerprint, policy: .standard)
        }
        XCTAssertNil(check(disk))
        XCTAssertNotNil(check(nil), "disk removed")

        var nowInternal = disk
        nowInternal.isInternal = true
        XCTAssertEqual(check(nowInternal), "The target reports as an internal disk")

        XCTAssertNotNil(check(disk, SystemContext(protectedWholeDisks: [disk.bsdName])), "became the boot disk")
        XCTAssertNotNil(check(disk, SystemContext(protectedWholeDisks: nil)), "boot disk unresolved")

        var swapped = disk
        swapped.registryEntryID = 7
        XCTAssertEqual(check(swapped), "The disk identity changed (registry entry ID)")
    }
}

final class ParsingTests: XCTestCase {
    func testBuildsFromDiskArbitrationDictionary() {
        let dictionary: [String: Any] = [
            "DAMediaWhole": true, "DADeviceInternal": false, "DADeviceProtocol": "USB",
            "DAMediaRemovable": true, "DAMediaEjectable": true, "DAMediaWritable": true,
            "DAMediaSize": NSNumber(value: 31_914_983_424 as UInt64), "DAMediaBlockSize": 512,
            "DAMediaBSDMajor": 1, "DAMediaBSDMinor": 20,
            "DAMediaName": "Generic STORAGE DEVICE Media", "DADeviceModel": "STORAGE DEVICE ",
            "DADeviceVendor": "Generic ", "DABusName": "AppleUSBXHCI",
        ]
        let facts = RegistryFacts(registryEntryID: 42, serialNumber: "S1", ancestorClasses: ["IOUSBHostDevice"], hasMediaAncestor: false, descendantVolumeRoles: [], volumeNames: ["NO NAME"])
        let disk = DiskDescription(bsdName: "disk4", daDescription: dictionary, registry: facts)
        XCTAssertEqual(disk.isWhole, true)
        XCTAssertEqual(disk.isInternal, false)
        XCTAssertEqual(disk.mediaSize, 31_914_983_424)
        XCTAssertEqual(disk.blockSize, 512)
        XCTAssertEqual(disk.bsdMinor, 20)
        XCTAssertEqual(disk.registryEntryID, 42)
        XCTAssertEqual(disk.displayName, "Generic STORAGE DEVICE")
        XCTAssertEqual(disk.sizeLabel, "31.9 GB")
        XCTAssertEqual(DiskGuard.evaluate(disk, context: SystemContext(protectedWholeDisks: ["disk0"]), policy: .standard), .eligible)
    }

    func testMissingAndMistypedKeysStayNil() {
        let disk = DiskDescription(
            bsdName: "disk4",
            daDescription: ["DAMediaWhole": "yes", "DAMediaSize": "big"],
            registry: RegistryFacts()
        )
        XCTAssertNil(disk.isWhole)
        XCTAssertNil(disk.isInternal)
        XCTAssertNil(disk.mediaSize)
        XCTAssertNil(disk.protocolName)
        XCTAssertEqual(disk.displayName, "disk4")
    }

    func testWholeDiskNames() {
        for good in ["disk0", "disk4", "disk18", "disk12345"] { XCTAssertTrue(BSDName.isWholeDiskName(good), good) }
        for bad in ["", "disk", "disk4s1", "rdisk4", "/dev/disk4", "disk4 ", "disk-4", "disk٤", "disk123456", "../disk4", "DISK4"] {
            XCTAssertFalse(BSDName.isWholeDiskName(bad), bad)
        }
    }

    func testSizeLabels() {
        XCTAssertEqual(SizeFormat.label(bytes: 17_825_792), "17.8 MB")
        XCTAssertEqual(SizeFormat.label(bytes: 31_914_983_424), "31.9 GB")
        XCTAssertEqual(SizeFormat.label(bytes: 2_000_000_000_000), "2.0 TB")
        XCTAssertEqual(SizeFormat.label(bytes: 512), "0.5 KB")
    }
}
