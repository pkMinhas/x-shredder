import XCTest
import CommonCrypto
@testable import Engine

final class PatternGeneratorTests: XCTestCase {
    let key = Data((0..<32).map { UInt8($0) })

    func testAnyBlockCanBeRegeneratedOnItsOwn() throws {
        let generator = PatternGenerator(key: key)
        let whole = try generator.data(pattern: .random, pass: 0, startBlock: 0, blocks: 64, blockSize: 512)
        for block in [0, 1, 17, 63] {
            let single = try generator.data(pattern: .random, pass: 0, startBlock: UInt64(block), blocks: 1, blockSize: 512)
            XCTAssertEqual(single, whole.subdata(in: (block * 512)..<((block + 1) * 512)))
        }
        // The same position gives the same bytes whatever the block size.
        let large = try generator.data(pattern: .random, pass: 0, startBlock: 2, blocks: 2, blockSize: 4096)
        let small = try generator.data(pattern: .random, pass: 0, startBlock: 16, blocks: 16, blockSize: 512)
        XCTAssertEqual(large, small)
    }

    /// Cross-check against AES-ECB of the counter block, computed separately.
    func testMatchesAESOfTheCounterBlock() throws {
        let generator = PatternGenerator(key: key)
        let pass = 3
        let block: UInt64 = 1_000_003
        let blockSize = 512
        let produced = try generator.data(pattern: .random, pass: pass, startBlock: block, blocks: 1, blockSize: blockSize)

        for aesBlock in [0, 1, 31] {
            var counter = [UInt8](repeating: 0, count: 16)
            withUnsafeBytes(of: UInt64(pass).bigEndian) { counter.replaceSubrange(0..<8, with: $0) }
            let index = block * UInt64(blockSize / 16) + UInt64(aesBlock)
            withUnsafeBytes(of: index.bigEndian) { counter.replaceSubrange(8..<16, with: $0) }
            var expected = [UInt8](repeating: 0, count: 16)
            var moved = 0
            let status = key.withUnsafeBytes {
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        $0.baseAddress, key.count, nil, counter, 16, &expected, 16, &moved)
            }
            XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
            XCTAssertEqual(Array(produced[(aesBlock * 16)..<((aesBlock + 1) * 16)]), expected)
        }
    }

    func testPassesKeysAndPositionsDiffer() throws {
        let generator = PatternGenerator(key: key)
        let a = try generator.data(pattern: .random, pass: 0, startBlock: 0, blocks: 1, blockSize: 512)
        XCTAssertNotEqual(a, try generator.data(pattern: .random, pass: 1, startBlock: 0, blocks: 1, blockSize: 512))
        XCTAssertNotEqual(a, try generator.data(pattern: .random, pass: 0, startBlock: 1, blocks: 1, blockSize: 512))
        let other = PatternGenerator(key: Data(repeating: 9, count: 32))
        XCTAssertNotEqual(a, try other.data(pattern: .random, pass: 0, startBlock: 0, blocks: 1, blockSize: 512))
        XCTAssertNotEqual(a, Data(count: 512))
    }

    func testZeroPatternOverwritesTheBuffer() throws {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1024, alignment: 16)
        defer { buffer.deallocate() }
        memset(buffer.baseAddress!, 0xFF, 1024)
        try PatternGenerator(key: key).fill(buffer, pattern: .zero, pass: 1, startBlock: 5, blockSize: 512)
        XCTAssertEqual(Data(buffer), Data(count: 1024))
    }

    func testRandomKeys() throws {
        let a = try PatternGenerator.randomKey()
        let b = try PatternGenerator.randomKey()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
    }
}

final class KeyWrapperTests: XCTestCase {
    func testRoundTripAndTamperDetection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kek-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyURL = directory.appendingPathComponent("kek")
        let wrapper = FileKeyWrapper(keyURL: keyURL)
        let runKey = try PatternGenerator.randomKey()

        let wrapped = try wrapper.wrap(runKey)
        XCTAssertNil(wrapped.range(of: runKey), "the run key must not appear in the wrapped form")
        XCTAssertEqual(try FileKeyWrapper(keyURL: keyURL).unwrap(wrapped), runKey)

        let mode = try FileManager.default.attributesOfItem(atPath: keyURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        var tampered = wrapped
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try wrapper.unwrap(tampered))

        let otherWrapper = FileKeyWrapper(keyURL: directory.appendingPathComponent("other"))
        XCTAssertThrowsError(try otherWrapper.unwrap(wrapped))
    }

    func testFileCheckpointStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCheckpointStore(url: directory.appendingPathComponent("checkpoint.json"))
        XCTAssertNil(try store.load())
        let checkpoint = Checkpoint(
            deviceIdentity: "card", blockSize: 512, blockCount: 100, plan: ErasePlan(zeroPass: true),
            passIndex: 1, phase: .write, nextBlock: 40, wrappedKey: Data([1, 2, 3]),
            startedAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
        try store.save(checkpoint)
        XCTAssertEqual(try store.load(), checkpoint)
        try store.clear()
        XCTAssertNil(try store.load())
        try store.clear()
    }
}
