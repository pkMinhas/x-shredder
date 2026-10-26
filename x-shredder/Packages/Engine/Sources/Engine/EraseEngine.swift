import Foundation

/// What to write. The first pass is always random data, because only
/// position-dependent data can expose a card that lies about its capacity.
public struct ErasePlan: Codable, Equatable, Sendable {
    public let passes: [PassPattern]

    /// One random pass, optionally followed by a zero pass. Every pass is
    /// verified. There is no way to turn verification off.
    public init(zeroPass: Bool = false) {
        passes = zeroPass ? [.random, .zero] : [.random]
    }
}

public enum EraseError: Error, Equatable, CustomStringConvertible {
    case invalidGeometry
    case keyGenerationFailed
    case patternFailed
    case cancelled
    case writeFailed(block: UInt64, attempts: Int, detail: String)
    case readFailed(block: UInt64, detail: String)
    case flushFailed(detail: String)
    /// Read-back did not match what was written. On the first pass this is
    /// also how a fake-capacity card shows up.
    case verificationMismatch(pass: Int, block: UInt64)
    case checkpointFailed(detail: String)

    public var description: String {
        switch self {
        case .invalidGeometry: return "The device reports an unusable block size or block count"
        case .keyGenerationFailed: return "Could not generate a random key"
        case .patternFailed: return "Could not generate the overwrite pattern"
        case .cancelled: return "Cancelled"
        case .writeFailed(let block, let attempts, let detail):
            return "Write failed at block \(block) after \(attempts) attempts: \(detail)"
        case .readFailed(let block, let detail):
            return "Read failed at block \(block) during verification: \(detail)"
        case .flushFailed(let detail): return "Could not flush the device: \(detail)"
        case .verificationMismatch(let pass, let block):
            return "Verification failed on pass \(pass + 1): block \(block) does not hold the data that was written"
        case .checkpointFailed(let detail): return "Could not save progress: \(detail)"
        }
    }
}

public struct EraseProgress: Codable, Equatable, Sendable {
    public var passIndex: Int
    public var passCount: Int
    public var pattern: PassPattern
    public var phase: ErasePhase
    /// Bytes handled in the current phase.
    public var phaseBytes: UInt64
    public var deviceBytes: UInt64
    /// 0 to 1 across every pass and phase.
    public var fraction: Double
    public var bytesPerSecond: Double
    public var secondsRemaining: Double?
}

public struct EraseSummary: Codable, Equatable, Sendable {
    public var plan: ErasePlan
    public var deviceBytes: UInt64
    public var passesVerified: Int
    /// True when this run continued from a checkpoint.
    public var resumed: Bool
    public var startedAt: Date
    public var finishedAt: Date
}

public final class EraseEngine {
    public struct Configuration: Sendable {
        public var chunkBytes = 4 * 1024 * 1024
        /// Retries after the first failed write of a chunk, then hard fail.
        public var writeRetries = 3
        /// Flush and save a checkpoint after this many bytes.
        public var checkpointIntervalBytes: UInt64 = 256 * 1024 * 1024
        public var progressInterval: TimeInterval = 0.25

        public init() {}
    }

    private let device: BlockDevice
    private let plan: ErasePlan
    private let checkpointing: Checkpointing?
    private let configuration: Configuration
    private let cancelLock = NSLock()
    private var cancelRequested = false

    public init(
        device: BlockDevice,
        plan: ErasePlan,
        checkpointing: Checkpointing? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.device = device
        self.plan = plan
        self.checkpointing = checkpointing
        self.configuration = configuration
    }

    /// Safe to call from any thread. The run stops at the next chunk.
    public func cancel() {
        cancelLock.lock()
        cancelRequested = true
        cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelRequested
    }

    /// Runs every pass: write the full range, flush, then read the full range
    /// back and compare. Blocks until done.
    ///
    /// The checkpoint is kept after an I/O failure so the run can be resumed,
    /// and removed after success, cancellation or a verification mismatch.
    public func run(progress: (EraseProgress) -> Void = { _ in }) throws -> EraseSummary {
        let blockSize = device.blockSize
        let blockCount = device.blockCount
        guard blockSize > 0, blockSize % 16 == 0, blockCount > 0,
              !blockCount.multipliedReportingOverflow(by: UInt64(blockSize)).overflow
        else { throw EraseError.invalidGeometry }

        var state = try startingState(blockSize: blockSize, blockCount: blockCount)
        let resumed = state.resumed
        let generator = PatternGenerator(key: state.key)
        let chunkBlocks = max(1, configuration.chunkBytes / blockSize)
        let chunkBytes = chunkBlocks * blockSize
        let pageSize = Int(getpagesize())
        let data = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkBytes, alignment: pageSize)
        let readback = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkBytes, alignment: pageSize)
        defer {
            // The buffers held pattern data, not user data, but clear them anyway.
            memset(data.baseAddress!, 0, chunkBytes)
            memset(readback.baseAddress!, 0, chunkBytes)
            data.deallocate()
            readback.deallocate()
        }

        var meter = ProgressMeter(
            passCount: plan.passes.count,
            deviceBytes: blockCount * UInt64(blockSize),
            interval: configuration.progressInterval
        )

        do {
            while state.passIndex < plan.passes.count {
                let pass = state.passIndex
                let pattern = plan.passes[pass]

                if state.phase == .write {
                    Log.engine.info("Pass \(pass + 1): writing from block \(state.nextBlock)")
                    var sinceCheckpoint: UInt64 = 0
                    var block = state.nextBlock
                    meter.begin(pass: pass, pattern: pattern, phase: .write, startBytes: block * UInt64(blockSize))
                    while block < blockCount {
                        if isCancelled { throw EraseError.cancelled }
                        let blocks = Int(min(UInt64(chunkBlocks), blockCount - block))
                        let chunk = UnsafeMutableRawBufferPointer(rebasing: data[0..<(blocks * blockSize)])
                        try generator.fill(chunk, pattern: pattern, pass: pass, startBlock: block, blockSize: blockSize)
                        try write(UnsafeRawBufferPointer(chunk), atBlock: block)
                        block += UInt64(blocks)
                        sinceCheckpoint += UInt64(chunk.count)
                        meter.advance(by: UInt64(chunk.count), report: progress)

                        if checkpointing != nil, sinceCheckpoint >= configuration.checkpointIntervalBytes, block < blockCount {
                            try flush()
                            state.nextBlock = block
                            try save(state, blockSize: blockSize, blockCount: blockCount)
                            sinceCheckpoint = 0
                        }
                    }
                    try flush()
                    state.phase = .verify
                    state.nextBlock = 0
                    try save(state, blockSize: blockSize, blockCount: blockCount)
                }

                // Verification always covers the full range, including after
                // a resume, so no block is trusted without being read back.
                Log.engine.info("Pass \(pass + 1): verifying")
                do {
                    try device.dropCaches()
                } catch {
                    throw EraseError.flushFailed(detail: String(describing: error))
                }
                var block: UInt64 = 0
                meter.begin(pass: pass, pattern: pattern, phase: .verify, startBytes: 0)
                while block < blockCount {
                    if isCancelled { throw EraseError.cancelled }
                    let blocks = Int(min(UInt64(chunkBlocks), blockCount - block))
                    let byteCount = blocks * blockSize
                    let expected = UnsafeMutableRawBufferPointer(rebasing: data[0..<byteCount])
                    let actual = UnsafeMutableRawBufferPointer(rebasing: readback[0..<byteCount])
                    try generator.fill(expected, pattern: pattern, pass: pass, startBlock: block, blockSize: blockSize)
                    do {
                        try device.read(into: actual, atBlock: block)
                    } catch {
                        throw EraseError.readFailed(block: block, detail: String(describing: error))
                    }
                    if memcmp(expected.baseAddress!, actual.baseAddress!, byteCount) != 0 {
                        var bad = 0
                        while bad < blocks - 1,
                              memcmp(expected.baseAddress! + bad * blockSize, actual.baseAddress! + bad * blockSize, blockSize) == 0 {
                            bad += 1
                        }
                        throw EraseError.verificationMismatch(pass: pass, block: block + UInt64(bad))
                    }
                    block += UInt64(blocks)
                    meter.advance(by: UInt64(byteCount), report: progress)
                }

                state.passIndex += 1
                state.phase = .write
                state.nextBlock = 0
                if state.passIndex < plan.passes.count {
                    try save(state, blockSize: blockSize, blockCount: blockCount)
                }
            }
        } catch let error as EraseError {
            switch error {
            case .cancelled, .verificationMismatch:
                clearCheckpoint()
            default:
                break
            }
            Log.engine.error("Erase stopped: \(error.description, privacy: .public)")
            throw error
        }

        meter.finish(report: progress)
        clearCheckpoint()
        Log.engine.info("Erase complete, \(self.plan.passes.count) pass(es) verified")
        return EraseSummary(
            plan: plan,
            deviceBytes: blockCount * UInt64(blockSize),
            passesVerified: plan.passes.count,
            resumed: resumed,
            startedAt: state.startedAt,
            finishedAt: Date()
        )
    }

    // MARK: I/O with retry

    private func write(_ chunk: UnsafeRawBufferPointer, atBlock block: UInt64) throws {
        var attempts = 0
        while true {
            attempts += 1
            do {
                try device.write(chunk, atBlock: block)
                return
            } catch {
                if attempts > configuration.writeRetries {
                    throw EraseError.writeFailed(block: block, attempts: attempts, detail: String(describing: error))
                }
                Log.engine.warning("Write at block \(block) failed, retry \(attempts)")
            }
        }
    }

    private func flush() throws {
        do {
            try device.flush()
        } catch {
            throw EraseError.flushFailed(detail: String(describing: error))
        }
    }

    // MARK: Checkpointing

    private struct RunState {
        var key: Data
        var passIndex = 0
        var phase = ErasePhase.write
        var nextBlock: UInt64 = 0
        var startedAt = Date()
        var resumed = false
    }

    private func startingState(blockSize: Int, blockCount: UInt64) throws -> RunState {
        if let checkpointing,
           let saved = try? checkpointing.store.load(),
           saved.version == Checkpoint.currentVersion,
           saved.deviceIdentity == checkpointing.deviceIdentity,
           saved.blockSize == blockSize,
           saved.blockCount == blockCount,
           saved.plan == plan,
           saved.passIndex < plan.passes.count,
           saved.nextBlock <= blockCount,
           let key = try? checkpointing.wrapper.unwrap(saved.wrappedKey),
           key.count == PatternGenerator.keyLength {
            Log.engine.info("Resuming at pass \(saved.passIndex + 1), block \(saved.nextBlock)")
            return RunState(
                key: key,
                passIndex: saved.passIndex,
                phase: saved.phase,
                nextBlock: saved.phase == .write ? saved.nextBlock : 0,
                startedAt: saved.startedAt,
                resumed: true
            )
        }
        // No usable checkpoint. Drop whatever is there and start a new run.
        clearCheckpoint()
        return RunState(key: try PatternGenerator.randomKey())
    }

    private func save(_ state: RunState, blockSize: Int, blockCount: UInt64) throws {
        guard let checkpointing else { return }
        do {
            try checkpointing.store.save(Checkpoint(
                deviceIdentity: checkpointing.deviceIdentity,
                blockSize: blockSize,
                blockCount: blockCount,
                plan: plan,
                passIndex: state.passIndex,
                phase: state.phase,
                nextBlock: state.nextBlock,
                wrappedKey: try checkpointing.wrapper.wrap(state.key),
                startedAt: state.startedAt,
                updatedAt: Date()
            ))
        } catch {
            throw EraseError.checkpointFailed(detail: String(describing: error))
        }
    }

    /// Removes the checkpoint and with it the only stored copy of the run key.
    private func clearCheckpoint() {
        guard let checkpointing else { return }
        do {
            try checkpointing.store.clear()
        } catch {
            Log.engine.error("Could not remove the checkpoint")
        }
    }
}

/// Tracks phase, throughput and time remaining.
struct ProgressMeter {
    let passCount: Int
    let deviceBytes: UInt64
    let interval: TimeInterval

    private var passIndex = 0
    private var pattern = PassPattern.random
    private var phase = ErasePhase.write
    private var phaseBytes: UInt64 = 0
    private var samples: [(time: TimeInterval, bytes: UInt64)] = []
    private var lastReport: TimeInterval = 0

    init(passCount: Int, deviceBytes: UInt64, interval: TimeInterval) {
        self.passCount = passCount
        self.deviceBytes = deviceBytes
        self.interval = interval
    }

    mutating func begin(pass: Int, pattern: PassPattern, phase: ErasePhase, startBytes: UInt64) {
        passIndex = pass
        self.pattern = pattern
        self.phase = phase
        phaseBytes = startBytes
        samples = [(ProcessInfo.processInfo.systemUptime, startBytes)]
        lastReport = 0
    }

    mutating func advance(by bytes: UInt64, report: (EraseProgress) -> Void) {
        phaseBytes += bytes
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, phaseBytes))
        // Throughput over roughly the last five seconds.
        while samples.count > 2, now - samples[0].time > 5 { samples.removeFirst() }
        guard now - lastReport >= interval || phaseBytes == deviceBytes else { return }
        lastReport = now
        report(snapshot())
    }

    mutating func finish(report: (EraseProgress) -> Void) {
        var final = snapshot()
        final.fraction = 1
        final.secondsRemaining = 0
        report(final)
    }

    private func snapshot() -> EraseProgress {
        let total = Double(deviceBytes) * Double(passCount) * 2
        let done = Double(deviceBytes) * Double(passIndex * 2 + (phase == .verify ? 1 : 0)) + Double(phaseBytes)
        var rate = 0.0
        if let first = samples.first, let last = samples.last, last.time > first.time {
            rate = Double(last.bytes - first.bytes) / (last.time - first.time)
        }
        return EraseProgress(
            passIndex: passIndex,
            passCount: passCount,
            pattern: pattern,
            phase: phase,
            phaseBytes: phaseBytes,
            deviceBytes: deviceBytes,
            fraction: total > 0 ? min(1, done / total) : 0,
            bytesPerSecond: rate,
            secondsRemaining: rate > 0 ? max(0, (total - done) / rate) : nil
        )
    }
}
