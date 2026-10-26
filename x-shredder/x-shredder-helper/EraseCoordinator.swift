import Foundation
import DiskGuard
import Engine

/// Owns the single erase the helper may run at a time.
final class EraseCoordinator: @unchecked Sendable {
    static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }()

    private let journal: Journal
    private let policy = Policy.active
    private let lock = NSLock()
    private let workQueue = DispatchQueue(label: "com.withpreet.x-shredder.erase", qos: .userInitiated)

    // Guarded by `lock`.
    private var clients: [NSXPCConnection] = []
    private var activeBSDName: String?
    private var engine: EraseEngine?
    private var lastProgress: EraseProgressMessage?
    private var userCancelled = false
    private var abortReason: String?

    init(journal: Journal) {
        self.journal = journal
    }

    // MARK: Clients

    func add(_ connection: NSXPCConnection) {
        lock.lock()
        clients.append(connection)
        lock.unlock()
    }

    func remove(_ connection: NSXPCConnection) {
        lock.lock()
        clients.removeAll { $0 === connection }
        lock.unlock()
    }

    private func broadcast(_ send: (EraseClientProtocol) -> Void) {
        lock.lock()
        let current = clients
        lock.unlock()
        for connection in current {
            if let client = connection.remoteObjectProxy as? EraseClientProtocol { send(client) }
        }
    }

    // MARK: Requests

    func status() -> HelperStatus {
        lock.lock()
        defer { lock.unlock() }
        return HelperStatus(
            version: Self.version,
            isErasing: activeBSDName != nil,
            activeBSDName: activeBSDName,
            lastProgress: lastProgress,
            lastResult: journal.lastResult,
            allowsTestDiskImages: Policy.allowsTestDiskImages
        )
    }

    func eligibleDisks() -> [DiskDescription] {
        let snapshot = LiveDiskSource().snapshot()
        return snapshot.disks.filter {
            DiskGuard.evaluate($0, context: snapshot.context, policy: policy).isEligible
        }
    }

    /// Returns `nil` when the erase was accepted, otherwise the refusal.
    func start(bsdName: String, optionsData: Data) -> String? {
        guard let options = EraseOptions.decodeStrict(optionsData) else {
            Log.helper.error("Refused a start request with malformed options")
            return "Malformed options"
        }
        // Full DiskGuard check, on fresh data, before anything else happens.
        // The same check runs again inside GuardedDiskAccess.open.
        let access = GuardedDiskAccess(policy: policy)
        let disk: DiskDescription
        do {
            (disk, _) = try access.validate(bsdName: bsdName)
        } catch {
            Log.helper.error("Refused erase request: \(String(describing: error), privacy: .public)")
            return String(describing: error)
        }

        lock.lock()
        guard activeBSDName == nil else {
            lock.unlock()
            return "An erase is already running"
        }
        activeBSDName = bsdName
        lastProgress = nil
        userCancelled = false
        abortReason = nil
        lock.unlock()

        let plan = ErasePlan(zeroPass: options.zeroPass)
        var result = EraseResult(
            id: UUID(),
            bsdName: bsdName,
            succeeded: false,
            cancelled: false,
            verification: "notCompleted",
            passes: plan.passes.map(\.rawValue),
            passesVerified: 0,
            errors: [],
            deviceModel: disk.displayName,
            deviceSizeBytes: disk.mediaSize ?? 0,
            serialNumber: disk.serialNumber,
            startedAt: Date(),
            finishedAt: Date(),
            resumed: false,
            helperVersion: Self.version
        )
        do {
            try journal.begin(result)
        } catch {
            lock.lock()
            activeBSDName = nil
            lock.unlock()
            return "Could not record the start of the erase"
        }

        Log.helper.info("Starting erase of \(bsdName, privacy: .public), \(plan.passes.count) pass(es)")
        workQueue.async { [self] in
            run(bsdName: bsdName, plan: plan, access: access, result: &result)
            journal.finish(result)
            lock.lock()
            activeBSDName = nil
            engine = nil
            lock.unlock()
            Log.helper.info("Erase of \(bsdName, privacy: .public) finished, succeeded: \(result.succeeded)")
            let data = Wire.encode(result)
            broadcast { $0.eraseFinished(data) }
        }
        return nil
    }

    func cancel() {
        lock.lock()
        userCancelled = true
        let running = engine
        lock.unlock()
        running?.cancel()
    }

    // MARK: The erase

    private func run(bsdName: String, plan: ErasePlan, access: GuardedDiskAccess, result: inout EraseResult) {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Erasing \(bsdName)")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            result.finishedAt = Date()
        }

        do {
            // Validate, fingerprint, unmount, open exclusively, validate and
            // compare the fingerprint again. Throws on any doubt.
            let disk = try access.open(bsdName: bsdName)
            defer { access.close(disk) }

            let device = try RawBlockDevice(fileDescriptor: disk.fileDescriptor, ownsDescriptor: false)
            guard disk.fingerprint.matchesGeometry(blockSize: device.blockSize, blockCount: device.blockCount) else {
                throw GuardError.fingerprintChanged("geometry of the opened device")
            }

            let identity = [
                disk.description.displayName,
                disk.description.serialNumber ?? "no-serial",
                String(disk.fingerprint.mediaSize),
                String(disk.fingerprint.blockSize),
            ].joined(separator: "|")
            let checkpointing = Checkpointing(
                store: FileCheckpointStore(url: Journal.directory.appendingPathComponent("checkpoint.json")),
                wrapper: FileKeyWrapper(keyURL: Journal.directory.appendingPathComponent("checkpoint.kek")),
                deviceIdentity: identity
            )
            let engine = EraseEngine(device: device, plan: plan, checkpointing: checkpointing)

            lock.lock()
            self.engine = engine
            let cancelledEarly = userCancelled
            lock.unlock()
            if cancelledEarly { engine.cancel() }

            // Final guard: stop at once if the target ever looks internal,
            // resolves to the boot disk, or stops being the validated disk.
            let inFlight = InFlightGuard(disk: disk, policy: policy) { [weak self, weak engine] reason in
                guard let self else { return }
                self.lock.lock()
                self.abortReason = reason
                self.lock.unlock()
                engine?.cancel()
            }
            defer { inFlight.stop() }

            let summary = try engine.run { [self] progress in
                let message = EraseProgressMessage(
                    bsdName: bsdName,
                    passIndex: progress.passIndex,
                    passCount: progress.passCount,
                    pattern: progress.pattern.rawValue,
                    phase: progress.phase.rawValue,
                    phaseBytes: progress.phaseBytes,
                    deviceBytes: progress.deviceBytes,
                    fraction: progress.fraction,
                    bytesPerSecond: progress.bytesPerSecond,
                    secondsRemaining: progress.secondsRemaining
                )
                lock.lock()
                lastProgress = message
                lock.unlock()
                let data = Wire.encode(message)
                broadcast { $0.eraseProgress(data) }
            }

            result.succeeded = true
            result.verification = "passed"
            result.passesVerified = summary.passesVerified
            result.resumed = summary.resumed
            result.startedAt = summary.startedAt
        } catch let error as EraseError {
            lock.lock()
            let reason = abortReason
            let byUser = userCancelled
            lock.unlock()
            switch error {
            case .cancelled:
                if let reason {
                    result.errors = ["Aborted by the safety guard: \(reason)"]
                } else {
                    result.cancelled = byUser
                    result.errors = ["Cancelled before completion. The card is partly overwritten and has not been verified."]
                }
            case .verificationMismatch(let pass, _):
                result.verification = "failed"
                result.passesVerified = pass
                var messages = [error.description]
                if pass == 0 {
                    messages.append("The card may report more capacity than it has, or it may be faulty.")
                }
                result.errors = messages
            default:
                result.errors = [error.description]
            }
        } catch {
            result.errors = [String(describing: error)]
        }
    }
}
