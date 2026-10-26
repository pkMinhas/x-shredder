import Foundation
import DiskArbitration

public enum GuardError: Error, Equatable, CustomStringConvertible {
    case invalidName
    case notFound
    case ineligible([RuleFailure])
    case fingerprintUnavailable
    case unmountFailed(String)
    case openFailed(Int32)
    case deviceNodeMismatch
    case fingerprintChanged(String)

    public var description: String {
        switch self {
        case .invalidName: return "Not a valid whole-disk name"
        case .notFound: return "Disk not found"
        case .ineligible(let failures):
            return "Disk is not eligible: " + failures.map(\.reason).joined(separator: "; ")
        case .fingerprintUnavailable: return "Could not read the disk identity"
        case .unmountFailed(let detail): return "Could not unmount the disk: \(detail)"
        case .openFailed(let code): return "Could not open the disk exclusively: \(String(cString: strerror(code)))"
        case .deviceNodeMismatch: return "The opened device does not match the validated disk"
        case .fingerprintChanged(let field): return "The disk changed after validation (\(field))"
        }
    }
}

/// A validated, unmounted, exclusively opened disk.
public struct GuardedDisk: Sendable {
    public let bsdName: String
    public let fileDescriptor: Int32
    public let description: DiskDescription
    public let fingerprint: DiskFingerprint
}

/// The only way to get a writable file descriptor for a disk.
///
/// Sequence: validate with fresh data, capture the fingerprint, unmount, open
/// exclusively, confirm the opened node is the validated disk, validate again
/// with fresh data, compare the fingerprint. Any failure closes the descriptor
/// and throws.
public struct GuardedDiskAccess: Sendable {
    public let policy: Policy
    public let source: LiveDiskSource

    public init(policy: Policy, source: LiveDiskSource = LiveDiskSource()) {
        self.policy = policy
        self.source = source
    }

    /// Validates a BSD name without touching the disk.
    public func validate(bsdName: String) throws -> (DiskDescription, DiskFingerprint) {
        guard BSDName.isWholeDiskName(bsdName) else { throw GuardError.invalidName }
        let snapshot = source.snapshot()
        guard let disk = snapshot.disk(named: bsdName) else { throw GuardError.notFound }
        let eligibility = DiskGuard.evaluate(disk, context: snapshot.context, policy: policy)
        guard eligibility.isEligible else { throw GuardError.ineligible(eligibility.failures) }
        guard let fingerprint = DiskFingerprint(disk) else { throw GuardError.fingerprintUnavailable }
        return (disk, fingerprint)
    }

    public func open(bsdName: String) throws -> GuardedDisk {
        let (_, fingerprint) = try validate(bsdName: bsdName)
        Log.guardLog.info("Validated \(bsdName, privacy: .public), unmounting")

        try Self.unmountWholeDisk(bsdName: bsdName)

        // O_EXLOCK makes every other open of the device fail with EBUSY for
        // as long as this descriptor is held.
        let fd = Darwin.open("/dev/r\(bsdName)", O_RDWR | O_EXLOCK | O_NONBLOCK)
        guard fd >= 0 else { throw GuardError.openFailed(errno) }

        do {
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }

            // Time-of-check to time-of-use: describe the disk again now that
            // it is open, and require the same identity.
            let (disk, current) = try validate(bsdName: bsdName)
            if let field = fingerprint.difference(from: current) {
                throw GuardError.fingerprintChanged(field)
            }
            try Self.confirmDeviceNode(fd: fd, matches: disk)
            Log.guardLog.info("Opened \(bsdName, privacy: .public) exclusively, identity unchanged")
            return GuardedDisk(bsdName: bsdName, fileDescriptor: fd, description: disk, fingerprint: fingerprint)
        } catch {
            Darwin.close(fd)
            Log.guardLog.error("Refused \(bsdName, privacy: .public) after open: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    public func close(_ disk: GuardedDisk) {
        Darwin.close(disk.fileDescriptor)
    }

    /// The descriptor must be a character device with the major and minor
    /// numbers DiskArbitration reported for the validated disk.
    static func confirmDeviceNode(fd: Int32, matches disk: DiskDescription) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFCHR,
              let major = disk.bsdMajor, let minor = disk.bsdMinor,
              Int32((info.st_rdev >> 24) & 0xff) == major,
              Int32(info.st_rdev & 0xffffff) == minor
        else { throw GuardError.deviceNodeMismatch }
    }

    private final class UnmountResult: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var failure: String?
    }

    static func unmountWholeDisk(bsdName: String, timeout: TimeInterval = 60) throws {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName)
        else { throw GuardError.unmountFailed("DiskArbitration unavailable") }

        let queue = DispatchQueue(label: "com.withpreet.x-shredder.unmount")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }

        let result = UnmountResult()
        let context = Unmanaged.passRetained(result).toOpaque()
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { _, dissenter, context in
            guard let context else { return }
            let result = Unmanaged<UnmountResult>.fromOpaque(context).takeRetainedValue()
            if let dissenter {
                let status = DADissenterGetStatus(dissenter)
                let detail = DADissenterGetStatusString(dissenter) as String?
                result.failure = detail ?? "status 0x\(String(UInt32(bitPattern: status), radix: 16))"
            }
            result.done.signal()
        }, context)

        guard result.done.wait(timeout: .now() + timeout) == .success else {
            throw GuardError.unmountFailed("timed out")
        }
        if let failure = result.failure { throw GuardError.unmountFailed(failure) }
    }
}

/// Re-checks the target while an erase is running.
public enum InFlightCheck {
    /// Returns a reason to abort, or `nil` when the disk is still the
    /// validated, eligible disk. A disk that can no longer be described is a
    /// reason to abort.
    public static func violation(
        disk: DiskDescription?,
        context: SystemContext,
        fingerprint: DiskFingerprint,
        policy: Policy
    ) -> String? {
        guard let disk else { return "The disk is no longer present" }
        if disk.isInternal == true { return "The target reports as an internal disk" }
        if context.protectedWholeDisks?.contains(disk.bsdName) != false {
            return "The target resolves to a disk that holds the running system"
        }
        let eligibility = DiskGuard.evaluate(disk, context: context, policy: policy)
        if let failure = eligibility.failures.first {
            return "The target is no longer eligible: \(failure.reason)"
        }
        guard let current = DiskFingerprint(disk) else { return "The disk identity can no longer be read" }
        if let field = fingerprint.difference(from: current) {
            return "The disk identity changed (\(field))"
        }
        return nil
    }
}

/// Runs `InFlightCheck` on a timer for the length of an erase.
public final class InFlightGuard: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    public init(
        disk: GuardedDisk,
        policy: Policy,
        source: LiveDiskSource = LiveDiskSource(),
        interval: TimeInterval = 2,
        onViolation: @escaping @Sendable (String) -> Void
    ) {
        let queue = DispatchQueue(label: "com.withpreet.x-shredder.in-flight-guard")
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        var fired = false
        timer.setEventHandler {
            guard !fired else { return }
            let snapshot = source.snapshot()
            if let reason = InFlightCheck.violation(
                disk: snapshot.disk(named: disk.bsdName),
                context: snapshot.context,
                fingerprint: disk.fingerprint,
                policy: policy
            ) {
                fired = true
                Log.guardLog.fault("In-flight guard abort on \(disk.bsdName, privacy: .public): \(reason, privacy: .public)")
                onViolation(reason)
            }
        }
        timer.resume()
    }

    public func stop() {
        timer.cancel()
    }

    deinit {
        timer.cancel()
    }
}
