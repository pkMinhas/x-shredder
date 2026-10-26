import XCTest
@testable import Engine

#if DEBUG
/// Runs the engine against a real raw device node backed by a scratch disk
/// image. Debug builds only, and only when XSHREDDER_DISK_IMAGE_TESTS=1,
/// because it attaches a disk image.
final class DiskImageTests: XCTestCase {
    func testEraseAndVerifyScratchDiskImage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["XSHREDDER_DISK_IMAGE_TESTS"] == "1")

        let megabytes = 21
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xshredder-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imagePath = directory.appendingPathComponent("scratch.dmg").path

        _ = try hdiutil(["create", "-size", "\(megabytes)m", "-layout", "NONE", "-type", "UDIF", "-o", imagePath])
        let attached = try hdiutil(["attach", "-nomount", imagePath])
        let node = String(attached.split(whereSeparator: \.isWhitespace).first ?? "")
        // Only ever touch the node hdiutil just handed back for our own image.
        guard node.hasPrefix("/dev/disk"), node.dropFirst("/dev/disk".count).allSatisfy(\.isNumber) else {
            return XCTFail("unexpected hdiutil output: \(attached)")
        }
        defer { _ = try? hdiutil(["detach", node, "-force"]) }
        let rawPath = node.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")

        do {
            let device = try RawBlockDevice(path: rawPath)
            // The geometry must be exactly the image we created.
            XCTAssertEqual(device.blockCount * UInt64(device.blockSize), UInt64(megabytes) * 1024 * 1024)
            XCTAssertEqual(device.blockSize, 512)

            let old = [UInt8](repeating: 0xA5, count: 1024 * 1024)
            try old.withUnsafeBytes { try device.write($0, atBlock: 0) }
            try device.flush()

            var configuration = EraseEngine.Configuration()
            configuration.chunkBytes = 1024 * 1024
            configuration.checkpointIntervalBytes = 4 * 1024 * 1024
            let store = MemoryCheckpointStore()
            let checkpointing = Checkpointing(store: store, wrapper: XORWrapper(), deviceIdentity: "scratch-image")
            var phases: [ErasePhase] = []
            let summary = try EraseEngine(device: device, plan: ErasePlan(zeroPass: true), checkpointing: checkpointing, configuration: configuration).run { progress in
                if phases.last != progress.phase { phases.append(progress.phase) }
            }
            XCTAssertEqual(summary.passesVerified, 2)
            XCTAssertEqual(phases, [.write, .verify, .write, .verify])
            XCTAssertGreaterThan(store.saveCount, 4)
            XCTAssertNil(store.checkpoint)

            let readback = UnsafeMutableRawBufferPointer.allocate(byteCount: 1024 * 1024, alignment: 16384)
            defer { readback.deallocate() }
            try device.read(into: readback, atBlock: 0)
            XCTAssertTrue(readback.allSatisfy { $0 == 0 }, "old data is gone after the zero pass")
        }

        // The image file itself, read through the filesystem, holds no old data.
        _ = try hdiutil(["detach", node])
        let image = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        XCTAssertNil(image.range(of: Data(repeating: 0xA5, count: 4096)))
    }

    private func hdiutil(_ arguments: [String]) throws -> String {
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
