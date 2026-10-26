import AppKit
import Foundation
import ServiceManagement
import DiskGuard

enum HelperInstallState: Equatable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
}

enum HelperError: Error, LocalizedError {
    case unsigned
    case connection(String)
    case badReply

    var errorDescription: String? {
        switch self {
        case .unsigned:
            return "This build has no team identifier in its signature, so the helper cannot be verified. Build and sign it with your development team."
        case .connection(let detail):
            return "Could not reach the helper: \(detail)"
        case .badReply:
            return "The helper sent a reply that could not be read."
        }
    }
}

/// Receives the helper's callbacks. XPC delivers them off the main thread.
private final class ClientEndpoint: NSObject, EraseClientProtocol {
    var onProgress: (@Sendable (EraseProgressMessage) -> Void)?
    var onFinished: (@Sendable (EraseResult) -> Void)?

    func eraseProgress(_ data: Data) {
        if let message = Wire.decode(EraseProgressMessage.self, from: data) { onProgress?(message) }
    }

    func eraseFinished(_ data: Data) {
        if let result = Wire.decode(EraseResult.self, from: data) { onFinished?(result) }
    }
}

/// Resumes a continuation once, whichever of reply or error arrives first.
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// The app's side of the XPC connection, plus helper registration.
final class HelperClient: @unchecked Sendable {
    private let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    private let endpoint = ClientEndpoint()
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    var onProgress: (@Sendable (EraseProgressMessage) -> Void)? {
        get { endpoint.onProgress }
        set { endpoint.onProgress = newValue }
    }

    var onFinished: (@Sendable (EraseResult) -> Void)? {
        get { endpoint.onFinished }
        set { endpoint.onFinished = newValue }
    }

    /// Called when the connection to the helper drops.
    var onDisconnected: (@Sendable () -> Void)?

    // MARK: Registration

    var installState: HelperInstallState {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        disconnect()
        try await service.unregister()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Selects the embedded helper in a Finder window, so it can be dragged
    /// into the Full Disk Access list.
    static func revealHelperInFinder() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/x-shredder-helper")
        NSWorkspace.shared.activateFileViewerSelecting([helper])
    }

    // MARK: Connection

    private func activeConnection() throws -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }

        // The helper must be our helper: same team, expected identifier.
        guard let requirement = PeerRequirement.requirement(forIdentifier: HelperConstants.helperBundleID) else {
            throw HelperError.unsigned
        }
        let created = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        created.setCodeSigningRequirement(requirement)
        created.remoteObjectInterface = NSXPCInterface(with: EraseHelperProtocol.self)
        created.exportedInterface = NSXPCInterface(with: EraseClientProtocol.self)
        created.exportedObject = endpoint
        let identity = ObjectIdentifier(created)
        let dropped: @Sendable () -> Void = { [weak self] in
            self?.connectionDropped(identity)
        }
        created.invalidationHandler = dropped
        created.interruptionHandler = dropped
        created.resume()
        connection = created
        return created
    }

    private func connectionDropped(_ identity: ObjectIdentifier) {
        lock.lock()
        let current = connection
        let isCurrent = current.map(ObjectIdentifier.init) == identity
        if isCurrent { connection = nil }
        lock.unlock()
        guard isCurrent else { return }
        current?.invalidationHandler = nil
        current?.interruptionHandler = nil
        current?.invalidate()
        onDisconnected?()
    }

    func disconnect() {
        lock.lock()
        let current = connection
        connection = nil
        lock.unlock()
        current?.invalidationHandler = nil
        current?.interruptionHandler = nil
        current?.invalidate()
    }

    private func call<T>(_ body: @escaping (EraseHelperProtocol, Once<T>) -> Void) async throws -> T {
        let connection = try activeConnection()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(with: .failure(HelperError.connection(error.localizedDescription)))
            }
            guard let helper = proxy as? EraseHelperProtocol else {
                once.resume(with: .failure(HelperError.badReply))
                return
            }
            body(helper, once)
        }
    }

    // MARK: Requests

    func status() async throws -> HelperStatus {
        try await call { helper, once in
            helper.status { data in
                if let status = Wire.decode(HelperStatus.self, from: data) {
                    once.resume(with: .success(status))
                } else {
                    once.resume(with: .failure(HelperError.badReply))
                }
            }
        }
    }

    func eligibleDisks() async throws -> [DiskDescription] {
        try await call { helper, once in
            helper.listEligibleDisks { data in
                if let disks = Wire.decode([DiskDescription].self, from: data) {
                    once.resume(with: .success(disks))
                } else {
                    once.resume(with: .failure(HelperError.badReply))
                }
            }
        }
    }

    /// Returns the helper's refusal message, or `nil` when the erase started.
    func startErase(bsdName: String, options: EraseOptions) async throws -> String? {
        try await call { helper, once in
            helper.startErase(bsdName: bsdName, options: Wire.encode(options)) { refusal in
                once.resume(with: .success(refusal))
            }
        }
    }

    func cancel() async throws {
        try await call { (helper, once: Once<Void>) in
            helper.cancel { once.resume(with: .success(())) }
        }
    }
}
