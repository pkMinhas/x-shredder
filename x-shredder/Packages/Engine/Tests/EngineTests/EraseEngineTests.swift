import XCTest
@testable import Engine

final class EraseEngineTests: XCTestCase {
    /// Small chunks and checkpoints so a tiny fake device spans many of each.
    private func configuration() -> EraseEngine.Configuration {
        var configuration = EraseEngine.Configuration()
        configuration.chunkBytes = 8 * 512
        configuration.checkpointIntervalBytes = 32 * 512
        configuration.progressInterval = 0
        return configuration
    }

    private func checkpointing(_ store: MemoryCheckpointStore, identity: String = "test-card") -> Checkpointing {
        Checkpointing(store: store, wrapper: XORWrapper(), deviceIdentity: identity)
    }

    // MARK: Success

    func testSingleRandomPassOverwritesAndVerifiesEveryBlock() throws {
        let device = try FakeBlockDevice(blockCount: 203) // not a multiple of the chunk size
        let store = MemoryCheckpointStore()
        var keyDuringRun: Data?
        var reports: [EraseProgress] = []

        let engine = EraseEngine(device: device, plan: ErasePlan(), checkpointing: checkpointing(store), configuration: configuration())
        let summary = try engine.run { progress in
            reports.append(progress)
            if keyDuringRun == nil, let wrapped = store.checkpoint?.wrappedKey {
                keyDuringRun = try? XORWrapper().unwrap(wrapped)
            }
        }

        XCTAssertEqual(summary.passesVerified, 1)
        XCTAssertEqual(summary.deviceBytes, 203 * 512)
        XCTAssertFalse(summary.resumed)
        XCTAssertEqual(device.blocksWritten, 203)
        XCTAssertGreaterThanOrEqual(device.flushCount, 1)
        XCTAssertEqual(device.dropCachesCount, 1, "caches dropped before verification")

        // The device holds exactly the keyed pattern and none of the old data.
        let key = try XCTUnwrap(keyDuringRun)
        let expected = try PatternGenerator(key: key).data(pattern: .random, pass: 0, startBlock: 0, blocks: 203, blockSize: 512)
        XCTAssertEqual(try device.contents(), expected)

        XCTAssertNil(store.checkpoint, "checkpoint and run key are deleted on completion")

        // Progress: write phase, then verify phase, ending at 100%.
        XCTAssertEqual(reports.first?.phase, .write)
        XCTAssertEqual(reports.last?.phase, .verify)
        XCTAssertEqual(reports.last?.fraction, 1)
        XCTAssertEqual(reports.last?.phaseBytes, 203 * 512)
        XCTAssertTrue(zip(reports, reports.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        XCTAssertTrue(reports.contains { $0.bytesPerSecond > 0 && $0.secondsRemaining != nil })
    }

    func testOptionalZeroPassLeavesZerosAndVerifiesBothPasses() throws {
        let device = try FakeBlockDevice(blockCount: 100)
        var reports: [EraseProgress] = []
        let summary = try EraseEngine(device: device, plan: ErasePlan(zeroPass: true), configuration: configuration()).run { reports.append($0) }

        XCTAssertEqual(summary.passesVerified, 2)
        XCTAssertEqual(try device.contents(), Data(count: 100 * 512))
        XCTAssertEqual(device.blocksWritten, 200)
        XCTAssertEqual(device.dropCachesCount, 2)
        let phases = reports.map { "\($0.passIndex)\($0.phase.rawValue)" }
        XCTAssertEqual(NSOrderedSet(array: phases).array as? [String], ["0write", "0verify", "1write", "1verify"])
    }

    func testPlanAlwaysStartsWithRandomAndCannotSkipVerification() {
        XCTAssertEqual(ErasePlan().passes, [.random])
        XCTAssertEqual(ErasePlan(zeroPass: true).passes, [.random, .zero])
    }

    func testFourKBlocks() throws {
        let device = try FakeBlockDevice(blockSize: 4096, blockCount: 37)
        var config = configuration()
        config.chunkBytes = 3 * 4096
        XCTAssertEqual(try EraseEngine(device: device, plan: ErasePlan(), configuration: config).run().passesVerified, 1)
    }

    // MARK: Write errors

    func testTransientWriteErrorIsRetried() throws {
        let device = try FakeBlockDevice(blockCount: 64)
        device.transientWriteFailures = [20: 3] // fails three times, the third retry succeeds
        let summary = try EraseEngine(device: device, plan: ErasePlan(), configuration: configuration()).run()
        XCTAssertEqual(summary.passesVerified, 1)
        XCTAssertEqual(device.transientWriteFailures[20], 0)
    }

    func testPersistentWriteErrorFailsHardAfterThreeRetries() throws {
        let device = try FakeBlockDevice(blockCount: 64)
        device.transientWriteFailures = [20: 100]
        XCTAssertThrowsError(try EraseEngine(device: device, plan: ErasePlan(), configuration: configuration()).run()) { error in
            guard case EraseError.writeFailed(let block, let attempts, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(block, 16, "start of the failing chunk")
            XCTAssertEqual(attempts, 4, "one attempt plus three retries")
        }
        XCTAssertEqual(device.transientWriteFailures[20], 96)
    }

    // MARK: Verification

    func testMismatchReportsTheBlockIndex() throws {
        let device = try FakeBlockDevice(blockCount: 128)
        device.corruptOnRead = [77]
        let store = MemoryCheckpointStore()
        XCTAssertThrowsError(try EraseEngine(device: device, plan: ErasePlan(), checkpointing: checkpointing(store), configuration: configuration()).run()) { error in
            XCTAssertEqual(error as? EraseError, .verificationMismatch(pass: 0, block: 77))
        }
        XCTAssertNil(store.checkpoint, "a failed verification is final, nothing to resume")
    }

    func testMismatchOnZeroPass() throws {
        let device = try FakeBlockDevice(blockCount: 64)
        var reports = 0
        let engine = EraseEngine(device: device, plan: ErasePlan(zeroPass: true), configuration: configuration())
        XCTAssertThrowsError(try engine.run { progress in
            reports += 1
            if progress.passIndex == 1 { device.corruptOnRead = [63] }
        }) { error in
            XCTAssertEqual(error as? EraseError, .verificationMismatch(pass: 1, block: 63))
        }
    }

    func testReadErrorDuringVerificationFails() throws {
        let device = try FakeBlockDevice(blockCount: 64)
        device.readFailsAtBlock = 40
        XCTAssertThrowsError(try EraseEngine(device: device, plan: ErasePlan(), configuration: configuration()).run()) { error in
            guard case EraseError.readFailed(let block, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(block, 40)
        }
    }

    /// A card that claims 256 blocks but stores 64. Late writes land on top
    /// of early ones, so the full read-back of pass 1 cannot match.
    func testFakeCapacityCardFailsTheFirstPass() throws {
        let device = try FakeBlockDevice(blockCount: 256, realBlockCount: 64)
        XCTAssertThrowsError(try EraseEngine(device: device, plan: ErasePlan(zeroPass: true), configuration: configuration()).run()) { error in
            guard case EraseError.verificationMismatch(let pass, let block) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(pass, 0, "caught on the first pass, before any zero pass could hide it")
            XCTAssertEqual(block, 0)
        }
    }

    // MARK: Checkpoint and resume

    func testResumeAfterCardRemoval() throws {
        let device = try FakeBlockDevice(blockCount: 300)
        let store = MemoryCheckpointStore()
        device.removedAtBlock = 150

        XCTAssertThrowsError(try EraseEngine(device: device, plan: ErasePlan(), checkpointing: checkpointing(store), configuration: configuration()).run()) { error in
            guard case EraseError.writeFailed = error else { return XCTFail("\(error)") }
        }
        let saved = try XCTUnwrap(store.checkpoint, "checkpoint survives an I/O failure")
        XCTAssertEqual(saved.phase, .write)
        XCTAssertEqual(saved.nextBlock, 128, "last flushed checkpoint boundary before the failure")
        XCTAssertNotEqual(try XORWrapper().unwrap(saved.wrappedKey), saved.wrappedKey)
        let key = try XORWrapper().unwrap(saved.wrappedKey)

        // Card back in. The second run continues instead of starting over.
        device.removedAtBlock = nil
        device.resetCounters()
        let summary = try EraseEngine(device: device, plan: ErasePlan(), checkpointing: checkpointing(store), configuration: configuration()).run()

        XCTAssertTrue(summary.resumed)
        XCTAssertEqual(device.lowestBlockWritten, 128)
        XCTAssertEqual(device.blocksWritten, 300 - 128)
        let expected = try PatternGenerator(key: key).data(pattern: .random, pass: 0, startBlock: 0, blocks: 300, blockSize: 512)
        XCTAssertEqual(try device.contents(), expected, "same key, whole device verified")
        XCTAssertNil(store.checkpoint)
    }

    /// Resuming on a different card of the same description must not pass:
    /// the blocks written before the interruption are not on this card.
    func testResumeOnADifferentCardFailsVerification() throws {
        let first = try FakeBlockDevice(blockCount: 300)
        let store = MemoryCheckpointStore()
        first.removedAtBlock = 150
        XCTAssertThrowsError(try EraseEngine(device: first, plan: ErasePlan(), checkpointing: checkpointing(store), configuration: configuration()).run())

        let second = try FakeBlockDevice(blockCount: 300)
        XCTAssertThrowsError(try EraseEngine(device: second, plan: ErasePlan(), checkpointing: checkpointing(store), configuration: configuration()).run()) { error in
            XCTAssertEqual(error as? EraseError, .verificationMismatch(pass: 0, block: 0))
        }
    }

    func testCheckpointForAnotherDeviceOrPlanIsIgnored() throws {
        let store = MemoryCheckpointStore()
        let interrupted = try FakeBlockDevice(blockCount: 300)
        interrupted.removedAtBlock = 150
        XCTAssertThrowsError(try EraseEngine(device: interrupted, plan: ErasePlan(), checkpointing: checkpointing(store), configuration: configuration()).run())
        let stale = try XCTUnwrap(store.checkpoint)

        for (identity, blockCount, plan) in [("other-card", UInt64(300), ErasePlan()), ("test-card", 301, ErasePlan()), ("test-card", 300, ErasePlan(zeroPass: true))] {
            store.checkpoint = stale
            let device = try FakeBlockDevice(blockCount: blockCount)
            let summary = try EraseEngine(device: device, plan: plan, checkpointing: checkpointing(store, identity: identity), configuration: configuration()).run()
            XCTAssertFalse(summary.resumed)
            XCTAssertEqual(device.lowestBlockWritten, 0)
        }
    }

    func testResumeInVerifyPhaseVerifiesFromTheStart() throws {
        let device = try FakeBlockDevice(blockCount: 200)
        let store = MemoryCheckpointStore()
        device.readFailsAtBlock = 120
        XCTAssertThrowsError(try EraseEngine(device: device, plan: ErasePlan(), checkpointing: checkpointing(store), configuration: configuration()).run())
        XCTAssertEqual(store.checkpoint?.phase, .verify)

        device.readFailsAtBlock = nil
        device.resetCounters()
        var firstVerifyBytes: UInt64?
        let summary = try EraseEngine(device: device, plan: ErasePlan(), checkpointing: checkpointing(store), configuration: configuration()).run { progress in
            if firstVerifyBytes == nil { firstVerifyBytes = progress.phaseBytes }
        }
        XCTAssertTrue(summary.resumed)
        XCTAssertEqual(device.blocksWritten, 0, "nothing is rewritten")
        XCTAssertEqual(firstVerifyBytes, 8 * 512, "verification restarts at block 0")
    }

    func testCheckpointSaveFailureStopsTheRun() throws {
        let device = try FakeBlockDevice(blockCount: 200)
        let store = MemoryCheckpointStore()
        store.failSaves = true
        XCTAssertThrowsError(try EraseEngine(device: device, plan: ErasePlan(), checkpointing: checkpointing(store), configuration: configuration()).run()) { error in
            guard case EraseError.checkpointFailed = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Cancel and geometry

    func testCancelStopsAndDiscardsTheCheckpoint() throws {
        let device = try FakeBlockDevice(blockCount: 400)
        let store = MemoryCheckpointStore()
        let engine = EraseEngine(device: device, plan: ErasePlan(), checkpointing: checkpointing(store), configuration: configuration())
        XCTAssertThrowsError(try engine.run { progress in
            if progress.phaseBytes >= 100 * 512 { engine.cancel() }
        }) { error in
            XCTAssertEqual(error as? EraseError, .cancelled)
        }
        XCTAssertLessThan(device.blocksWritten, 400)
        XCTAssertNil(store.checkpoint)
    }

    func testInvalidGeometryIsRefused() throws {
        final class Broken: BlockDevice {
            var blockSize = 0
            var blockCount: UInt64 = 10
            func write(_ buffer: UnsafeRawBufferPointer, atBlock block: UInt64) throws { XCTFail("must not write") }
            func read(into buffer: UnsafeMutableRawBufferPointer, atBlock block: UInt64) throws {}
            func flush() throws {}
            func dropCaches() throws {}
        }
        let device = Broken()
        for (size, count) in [(0, UInt64(10)), (500, 10), (512, 0), (512, UInt64.max)] {
            device.blockSize = size
            device.blockCount = count
            XCTAssertThrowsError(try EraseEngine(device: device, plan: ErasePlan()).run()) { error in
                XCTAssertEqual(error as? EraseError, .invalidGeometry)
            }
        }
    }
}
