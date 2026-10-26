import XCTest
@testable import DiskGuard

/// Read-only checks against the machine running the tests.
final class LiveTests: XCTestCase {
    func testThisMachinesSystemDisksAreRefused() throws {
        let snapshot = LiveDiskSource().snapshot()
        let protected = try XCTUnwrap(snapshot.context.protectedWholeDisks, "boot disk must resolve")
        XCTAssertFalse(protected.isEmpty)
        XCTAssertFalse(snapshot.disks.isEmpty)

        var policies = [Policy.standard]
        #if DEBUG
        var debug = Policy.standard
        debug.allowTestDiskImages = true
        policies.append(debug)
        #endif

        for policy in policies {
            for disk in snapshot.disks {
                let verdict = DiskGuard.evaluate(disk, context: snapshot.context, policy: policy)
                if protected.contains(disk.bsdName) || disk.isInternal != false && disk.protocolName != "Virtual Interface" {
                    XCTAssertFalse(verdict.isEligible, "\(disk.bsdName) must be refused")
                }
                if disk.isInternal == true {
                    XCTAssertTrue(verdict.failures.contains { $0.rule == .notInternal })
                }
            }
        }
    }

    func testGuardedAccessRefusesTheBootDiskWithoutTouchingIt() throws {
        let snapshot = LiveDiskSource().snapshot()
        let access = GuardedDiskAccess(policy: .standard)
        for name in try XCTUnwrap(snapshot.context.protectedWholeDisks) {
            // validate() only reads descriptions. It runs before any unmount
            // or open in open(bsdName:).
            XCTAssertThrowsError(try access.validate(bsdName: name)) { error in
                guard case GuardError.ineligible = error else {
                    return XCTFail("expected ineligible for \(name), got \(error)")
                }
            }
        }
        for name in ["disk0s1", "/dev/disk0", "rdisk0", "disk0; rm", ""] {
            XCTAssertThrowsError(try access.validate(bsdName: name)) { error in
                XCTAssertEqual(error as? GuardError, .invalidName)
            }
        }
        XCTAssertThrowsError(try access.validate(bsdName: "disk99999")) { error in
            XCTAssertEqual(error as? GuardError, .notFound)
        }
    }
}

#if DEBUG
/// Opens a scratch disk image through the full guarded sequence. Opt in with
/// XSHREDDER_DISK_IMAGE_TESTS=1 because it attaches a disk image.
final class DiskImageGuardTests: XCTestCase {
    func testGuardedOpenOfScratchImage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["XSHREDDER_DISK_IMAGE_TESTS"] == "1")
        let image = try ScratchImage(megabytes: 19)
        defer { image.detach() }

        XCTAssertThrowsError(try GuardedDiskAccess(policy: .standard).open(bsdName: image.bsdName), "release policy refuses images")

        var policy = Policy.standard
        policy.allowTestDiskImages = true
        let access = GuardedDiskAccess(policy: policy)
        let disk = try access.open(bsdName: image.bsdName)
        XCTAssertEqual(disk.fingerprint.mediaSize, 19 * 1024 * 1024)

        // Exclusive: nothing else can open the device while we hold it.
        let second = Darwin.open("/dev/r\(image.bsdName)", O_RDWR)
        XCTAssertEqual(second, -1)
        XCTAssertEqual(errno, EBUSY)

        let snapshot = LiveDiskSource().snapshot()
        XCTAssertNil(InFlightCheck.violation(
            disk: snapshot.disk(named: image.bsdName), context: snapshot.context,
            fingerprint: disk.fingerprint, policy: policy))

        access.close(disk)
        image.detach()
        let after = LiveDiskSource().snapshot()
        XCTAssertNotNil(InFlightCheck.violation(
            disk: after.disk(named: image.bsdName), context: after.context,
            fingerprint: disk.fingerprint, policy: policy), "removed disk is a violation")
    }
}

final class ScratchImage {
    let bsdName: String
    private let directory: URL
    private var attached = true

    init(megabytes: Int) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("xshredder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("scratch.dmg").path
        _ = try Self.run(["create", "-size", "\(megabytes)m", "-layout", "NONE", "-type", "UDIF", "-o", path])
        let output = try Self.run(["attach", "-nomount", path])
        let device = output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init) ?? ""
        guard device.hasPrefix("/dev/disk") else { throw CocoaError(.fileReadUnknown) }
        bsdName = String(device.dropFirst("/dev/".count))
    }

    func detach() {
        guard attached else { return }
        attached = false
        _ = try? Self.run(["detach", "/dev/\(bsdName)", "-force"])
        try? FileManager.default.removeItem(at: directory)
    }

    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
