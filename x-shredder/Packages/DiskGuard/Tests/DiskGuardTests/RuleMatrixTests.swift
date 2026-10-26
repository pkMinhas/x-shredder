import XCTest
@testable import DiskGuard

final class RuleMatrixTests: XCTestCase {
    // MARK: Recorded and constructed fixtures

    func testFixtureVerdicts() throws {
        // nil means the disk must be eligible. Otherwise every listed rule
        // must be among the failures.
        let expected: [(String, [Rule]?)] = [
            ("usb-reader-sd-card", nil),
            ("usb-hard-drive", nil),
            ("internal-ssd-boot-disk", [.notInternal, .notBootOrSystem, .removable, .protocolAllowed]),
            ("apfs-synthesized-container", [.notInternal, .notVirtual, .notBootOrSystem, .protocolAllowed]),
            ("disk-image-writable", [.notInternal, .notVirtual, .protocolAllowed]),
            ("disk-image-readonly", [.notInternal, .notVirtual, .protocolAllowed, .writable]),
            ("builtin-sd-slot", nil),
            ("usb-hard-drive-oversize", [.sizeCap]),
            ("usb-drive-with-system-volumes", [.notBootOrSystem]),
            ("usb-external-boot-disk", [.notBootOrSystem]),
            ("usb-reader-write-protected", [.writable]),
            ("thunderbolt-ssd", [.protocolAllowed]),
        ]
        for (name, rules) in expected {
            let fixture = try Fixtures.disk(name)
            let verdict = DiskGuard.evaluate(fixture.description, context: fixture.context, policy: .standard)
            if let rules {
                XCTAssertFalse(verdict.isEligible, "\(name) must be refused")
                let failed = Set(verdict.failures.map(\.rule))
                for rule in rules {
                    XCTAssertTrue(failed.contains(rule), "\(name) must fail \(rule)")
                }
            } else {
                XCTAssertEqual(verdict, .eligible, "\(name) should be eligible")
            }
        }
    }

    /// Without the exception, the built-in slot fails on rule 2 alone.
    func testBuiltInSlotNeedsTheException() throws {
        let fixture = try Fixtures.disk("builtin-sd-slot")
        var strict = Policy.standard
        strict.allowBuiltInSDSlot = false
        let verdict = DiskGuard.evaluate(fixture.description, context: fixture.context, policy: strict)
        XCTAssertEqual(verdict.failures.map(\.rule), [.notInternal])
        XCTAssertTrue(Policy.standard.allowBuiltInSDSlot)
        XCTAssertFalse(Policy(allowedProtocols: ["USB"], maxSizeBytes: 1).allowBuiltInSDSlot)
    }

    /// The exception covers only a disk driven by the SDXC slot driver. Every
    /// other rule still applies to the slot.
    func testBuiltInSlotExceptionIsNarrow() throws {
        let slot = try Fixtures.disk("builtin-sd-slot")
        let ssd = try Fixtures.disk("internal-ssd-boot-disk")
        XCTAssertTrue(Rules.isBuiltInSDSlot(slot.description))
        XCTAssertFalse(Rules.isBuiltInSDSlot(ssd.description))

        let notTheSlot: [(String, (inout DiskDescription) -> Void)] = [
            ("internal unknown", { $0.isInternal = nil }),
            ("other protocol", { $0.protocolName = "USB" }),
            ("no protocol", { $0.protocolName = nil }),
            ("layered", { $0.hasMediaAncestor = true }),
            ("no ancestors", { $0.ancestorClasses = nil }),
            ("internal SSD driver", { $0.ancestorClasses = ["IOBlockStorageDriver", "IONVMeBlockStorageDevice", "AppleANS3NVMeController"] }),
            ("SDXC driver further up", { $0.ancestorClasses = ["IOBlockStorageDriver", "IONVMeBlockStorageDevice", "AppleSDXCBlockStorageDevice", "AppleSDXCSlot", "AppleSDXC"] }),
            ("slot class missing", { $0.ancestorClasses = ["IOBlockStorageDriver", "AppleSDXCBlockStorageDevice", "AppleSDXC"] }),
            ("disk image underneath", { $0.ancestorClasses = ["IOBlockStorageDriver", "AppleSDXCBlockStorageDevice", "AppleSDXCSlot", "AppleSDXC", "AppleDiskImageDevice"] }),
        ]
        for (label, mutate) in notTheSlot {
            var disk = slot.description
            mutate(&disk)
            XCTAssertFalse(Rules.isBuiltInSDSlot(disk), "\(label) is not the built-in slot")
            XCTAssertFalse(DiskGuard.evaluate(disk, context: slot.context, policy: .standard).isEligible, "\(label) must be refused")
        }

        let otherRules: [(String, Rule, (inout DiskDescription) -> Void)] = [
            ("partition", .wholeDisk, { $0.isWhole = false }),
            ("holds the running system", .notBootOrSystem, { $0.bsdName = "disk0" }),
            ("system volumes", .notBootOrSystem, { $0.descendantVolumeRoles = ["System"] }),
            ("not removable", .removable, { $0.isRemovable = false; $0.isEjectable = false }),
            ("oversize", .sizeCap, { $0.mediaSize = 4_000_000_000_000 }),
            ("write-protected", .writable, { $0.isWritable = false }),
        ]
        for (label, rule, mutate) in otherRules {
            var disk = slot.description
            mutate(&disk)
            let verdict = DiskGuard.evaluate(disk, context: slot.context, policy: .standard)
            XCTAssertTrue(verdict.failures.contains { $0.rule == rule }, "slot \(label) must fail \(rule)")
        }

        var noSecureDigital = Policy.standard
        noSecureDigital.allowedProtocols = ["USB"]
        XCTAssertFalse(DiskGuard.evaluate(slot.description, context: slot.context, policy: noSecureDigital).isEligible)
    }

    // MARK: Missing keys fail closed

    func testEveryUnreadableKeyIsRefused() throws {
        let base = try Fixtures.eligibleCard()
        let cases: [(String, Rule, (inout DiskDescription) -> Void)] = [
            ("isWhole", .wholeDisk, { $0.isWhole = nil }),
            ("isInternal", .notInternal, { $0.isInternal = nil }),
            ("protocolName", .protocolAllowed, { $0.protocolName = nil }),
            ("protocolName", .notVirtual, { $0.protocolName = nil }),
            ("hasMediaAncestor", .notVirtual, { $0.hasMediaAncestor = nil }),
            ("ancestorClasses", .notVirtual, { $0.ancestorClasses = nil }),
            ("descendantVolumeRoles", .notBootOrSystem, { $0.descendantVolumeRoles = nil }),
            ("removable and ejectable", .removable, { $0.isRemovable = nil; $0.isEjectable = nil }),
            ("mediaSize", .sizeCap, { $0.mediaSize = nil }),
            ("blockSize", .sizeCap, { $0.blockSize = nil }),
            ("isWritable", .writable, { $0.isWritable = nil }),
        ]
        for (key, rule, mutate) in cases {
            var disk = base.description
            mutate(&disk)
            let verdict = DiskGuard.evaluate(disk, context: base.context, policy: .standard)
            XCTAssertTrue(verdict.failures.contains { $0.rule == rule }, "missing \(key) must fail \(rule)")
        }
    }

    func testUnresolvedBootDiskRefusesEverything() throws {
        let base = try Fixtures.eligibleCard()
        let verdict = DiskGuard.evaluate(
            base.description,
            context: SystemContext(protectedWholeDisks: nil),
            policy: .standard
        )
        XCTAssertEqual(verdict.failures.map(\.rule), [.notBootOrSystem])
    }

    func testDescriptionWithNoReadableKeysFailsEveryRule() {
        let verdict = DiskGuard.evaluate(
            DiskDescription(bsdName: "disk9"),
            context: SystemContext(protectedWholeDisks: nil),
            policy: .standard
        )
        XCTAssertEqual(Set(verdict.failures.map(\.rule)), Set(Rule.allCases))
    }

    // MARK: Exhaustive matrix

    /// Every combination of good, bad and unreadable values. Exactly one
    /// shape is eligible: every rule input present and good.
    func testExhaustiveMatrix() throws {
        let base = try Fixtures.eligibleCard().description
        let tri: [Bool?] = [true, false, nil]
        let protocols: [String?] = ["USB", "Secure Digital", "Virtual Interface", "SATA", "Apple Fabric", "PCI-Express", "Thunderbolt", "SomethingNew", "", nil]
        let sizes: [UInt64?] = [31_914_983_424, 2_000_000_000_000, 2_000_000_000_512, 0, 1000, nil]
        let roleSets: [[String]?] = [[], ["System"], ["Data"], ["Preboot"], ["Recovery"], ["VM"], nil]
        let contexts: [Set<String>?] = [["disk0", "disk3"], ["disk0", "disk4"], nil]
        let names = ["disk4", "disk4s1"]

        var checked = 0
        var eligibleCount = 0
        for name in names {
            for whole in tri {
                for isInternal in tri {
                    for proto in protocols {
                        for removable in tri {
                            for ejectable in tri {
                                for writable in tri {
                                    for layered in tri {
                                        for size in sizes {
                                            for roles in roleSets {
                                                for protected in contexts {
                                                    var disk = base
                                                    disk.bsdName = name
                                                    disk.isWhole = whole
                                                    disk.isInternal = isInternal
                                                    disk.protocolName = proto
                                                    disk.isRemovable = removable
                                                    disk.isEjectable = ejectable
                                                    disk.isWritable = writable
                                                    disk.hasMediaAncestor = layered
                                                    disk.mediaSize = size
                                                    disk.descendantVolumeRoles = roles
                                                    let verdict = DiskGuard.evaluate(
                                                        disk,
                                                        context: SystemContext(protectedWholeDisks: protected),
                                                        policy: .standard
                                                    )
                                                    let shouldBeEligible =
                                                        name == "disk4"
                                                        && whole == true
                                                        && isInternal == false
                                                        && (proto == "USB" || proto == "Secure Digital")
                                                        && (removable == true || ejectable == true)
                                                        && writable == true
                                                        && layered == false
                                                        && (size == 31_914_983_424 || size == 2_000_000_000_000)
                                                        && roles == []
                                                        && protected == ["disk0", "disk3"]
                                                    if verdict.isEligible != shouldBeEligible {
                                                        XCTFail("Wrong verdict for \(disk) protected=\(String(describing: protected))")
                                                        return
                                                    }
                                                    checked += 1
                                                    if shouldBeEligible { eligibleCount += 1 }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 2 * 3 * 3 * 10 * 3 * 3 * 3 * 3 * 6 * 7 * 3)
        // 2 protocols, 5 removable or ejectable combinations, 2 sizes.
        XCTAssertEqual(eligibleCount, 2 * 5 * 2)
    }

    /// Internal, virtual, boot and unknown-protocol disks are refused no
    /// matter what every other field says.
    func testHardRefusalsCannotBeOutvoted() throws {
        let base = try Fixtures.eligibleCard()
        let breakers: [(String, (inout DiskDescription) -> Void)] = [
            ("internal", { $0.isInternal = true }),
            ("virtual protocol", { $0.protocolName = "Virtual Interface" }),
            ("disk image model", { $0.deviceModel = "Disk Image" }),
            ("disk image driver", { $0.ancestorClasses = ["IOBlockStorageDriver", "AppleDiskImageDevice"] }),
            ("legacy disk image driver", { $0.ancestorClasses = ["IOHDIXHDDriveOutKernel", "IOHDIXController"] }),
            ("APFS synthesized", { $0.hasMediaAncestor = true }),
            ("boot disk", { $0.bsdName = "disk0" }),
            ("unknown protocol", { $0.protocolName = "Quantum Link" }),
            ("partition", { $0.isWhole = false }),
            ("slice name", { $0.bsdName = "disk4s1" }),
        ]
        for (label, mutate) in breakers {
            var disk = base.description
            mutate(&disk)
            XCTAssertFalse(
                DiskGuard.evaluate(disk, context: base.context, policy: .standard).isEligible,
                "\(label) must be refused"
            )
        }
    }

    func testPolicyValuesAreApplied() throws {
        let base = try Fixtures.eligibleCard()
        var usbOnly = Policy.standard
        usbOnly.allowedProtocols = ["Secure Digital"]
        XCTAssertFalse(DiskGuard.evaluate(base.description, context: base.context, policy: usbOnly).isEligible)

        var small = Policy.standard
        small.maxSizeBytes = 16_000_000_000
        XCTAssertFalse(DiskGuard.evaluate(base.description, context: base.context, policy: small).isEligible)

        XCTAssertEqual(Policy.standard.allowedProtocols, ["USB", "Secure Digital"])
        XCTAssertEqual(Policy.standard.maxSizeBytes, 2_000_000_000_000)
    }

    // MARK: Debug-only test disk images

    #if DEBUG
    func testDiskImagesNeedTheDebugPolicy() throws {
        let image = try Fixtures.disk("disk-image-writable")
        XCTAssertFalse(Policy.standard.allowTestDiskImages)
        XCTAssertFalse(DiskGuard.evaluate(image.description, context: image.context, policy: .standard).isEligible)

        var debug = Policy.standard
        debug.allowTestDiskImages = true
        XCTAssertEqual(DiskGuard.evaluate(image.description, context: image.context, policy: debug), .eligible)
    }

    func testDebugPolicyStillRefusesEverythingElse() throws {
        var debug = Policy.standard
        debug.allowTestDiskImages = true
        for name in ["internal-ssd-boot-disk", "apfs-synthesized-container", "disk-image-readonly", "usb-drive-with-system-volumes", "usb-external-boot-disk", "thunderbolt-ssd"] {
            let fixture = try Fixtures.disk(name)
            XCTAssertFalse(
                DiskGuard.evaluate(fixture.description, context: fixture.context, policy: debug).isEligible,
                "\(name) must be refused under the debug policy"
            )
        }

        let image = try Fixtures.disk("disk-image-writable")
        var large = image.description
        large.mediaSize = debug.maxTestDiskImageBytes + 512
        XCTAssertFalse(DiskGuard.evaluate(large, context: image.context, policy: debug).isEligible)

        var internalImage = image.description
        internalImage.isInternal = true
        XCTAssertFalse(DiskGuard.evaluate(internalImage, context: image.context, policy: debug).isEligible)

        var layered = image.description
        layered.hasMediaAncestor = true
        XCTAssertFalse(DiskGuard.evaluate(layered, context: image.context, policy: debug).isEligible)

        var protected = image.context
        protected.protectedWholeDisks?.insert(image.description.bsdName)
        XCTAssertFalse(DiskGuard.evaluate(image.description, context: protected, policy: debug).isEligible)
    }
    #endif
}
