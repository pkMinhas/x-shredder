import Foundation
@testable import Engine

/// File-backed device for tests, with switches for the failures the engine
/// has to survive or report.
final class FakeBlockDevice: BlockDevice {
    let blockSize: Int
    let blockCount: UInt64
    let url: URL
    private let handle: FileHandle

    /// Real capacity in blocks. Smaller than `blockCount` models a
    /// fake-capacity card: writes past the end wrap around to the start.
    var realBlockCount: UInt64
    /// Writes touching this block fail this many times, then succeed.
    var transientWriteFailures: [UInt64: Int] = [:]
    /// Every write at or after this block fails, as if the card was pulled.
    var removedAtBlock: UInt64?
    /// These blocks come back with one flipped bit.
    var corruptOnRead: Set<UInt64> = []
    var readFailsAtBlock: UInt64?

    private(set) var blocksWritten: UInt64 = 0
    private(set) var lowestBlockWritten: UInt64?
    private(set) var flushCount = 0
    private(set) var dropCachesCount = 0

    init(blockSize: Int = 512, blockCount: UInt64, realBlockCount: UInt64? = nil) throws {
        self.blockSize = blockSize
        self.blockCount = blockCount
        self.realBlockCount = realBlockCount ?? blockCount
        url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-device-\(UUID().uuidString).bin")
        // Start with recognisable "old data" so an unwritten block is obvious.
        let old = Data(repeating: 0xA5, count: Int(self.realBlockCount) * blockSize)
        try old.write(to: url)
        handle = try FileHandle(forUpdating: url)
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    func resetCounters() {
        blocksWritten = 0
        lowestBlockWritten = nil
    }

    func contents() throws -> Data {
        try handle.synchronize()
        return try Data(contentsOf: url)
    }

    func write(_ buffer: UnsafeRawBufferPointer, atBlock block: UInt64) throws {
        precondition(buffer.count % blockSize == 0)
        let blocks = UInt64(buffer.count / blockSize)
        precondition(block + blocks <= blockCount, "write past the advertised end")
        if let removedAtBlock, block + blocks > removedAtBlock {
            throw DeviceIOError(operation: "write", code: ENXIO)
        }
        for index in block..<(block + blocks) {
            if let remaining = transientWriteFailures[index], remaining > 0 {
                transientWriteFailures[index] = remaining - 1
                throw DeviceIOError(operation: "write", code: EIO)
            }
        }
        for index in 0..<blocks {
            let physical = (block + index) % realBlockCount
            try handle.seek(toOffset: physical * UInt64(blockSize))
            let slice = UnsafeRawBufferPointer(rebasing: buffer[(Int(index) * blockSize)..<(Int(index + 1) * blockSize)])
            try handle.write(contentsOf: Data(slice))
        }
        blocksWritten += blocks
        lowestBlockWritten = min(lowestBlockWritten ?? block, block)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, atBlock block: UInt64) throws {
        precondition(buffer.count % blockSize == 0)
        let blocks = UInt64(buffer.count / blockSize)
        for index in 0..<blocks {
            let logical = block + index
            if logical == readFailsAtBlock { throw DeviceIOError(operation: "read", code: EIO) }
            let physical = logical % realBlockCount
            try handle.seek(toOffset: physical * UInt64(blockSize))
            var data = try handle.read(upToCount: blockSize) ?? Data()
            precondition(data.count == blockSize)
            if corruptOnRead.contains(logical) { data[7] ^= 0x10 }
            data.copyBytes(to: buffer.baseAddress!.advanced(by: Int(index) * blockSize).assumingMemoryBound(to: UInt8.self), count: blockSize)
        }
    }

    func flush() throws {
        flushCount += 1
    }

    func dropCaches() throws {
        dropCachesCount += 1
    }
}

final class MemoryCheckpointStore: CheckpointStore {
    var checkpoint: Checkpoint?
    var saveCount = 0
    var failSaves = false

    func load() throws -> Checkpoint? { checkpoint }

    func save(_ checkpoint: Checkpoint) throws {
        if failSaves { throw CocoaError(.fileWriteNoPermission) }
        self.checkpoint = checkpoint
        saveCount += 1
    }

    func clear() throws { checkpoint = nil }
}

/// Reversible but not secret. Lets tests read the key back out.
struct XORWrapper: KeyWrapping {
    func wrap(_ key: Data) throws -> Data { Data(key.map { $0 ^ 0x5A }) }
    func unwrap(_ wrapped: Data) throws -> Data { Data(wrapped.map { $0 ^ 0x5A }) }
}

extension PatternGenerator {
    func data(pattern: PassPattern, pass: Int, startBlock: UInt64, blocks: Int, blockSize: Int) throws -> Data {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: blocks * blockSize, alignment: 16)
        defer { buffer.deallocate() }
        try fill(buffer, pattern: pattern, pass: pass, startBlock: startBlock, blockSize: blockSize)
        return Data(buffer)
    }
}
