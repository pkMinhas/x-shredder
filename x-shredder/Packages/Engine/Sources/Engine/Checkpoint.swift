import Foundation
import CryptoKit

public enum ErasePhase: String, Codable, Sendable {
    case write
    case verify
}

/// Progress saved to disk so an interrupted run can continue.
public struct Checkpoint: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = Checkpoint.currentVersion
    /// Stable description of the device (model, serial, size). The registry
    /// entry ID is not stable across re-insertion, so it is not used here.
    public var deviceIdentity: String
    public var blockSize: Int
    public var blockCount: UInt64
    public var plan: ErasePlan
    public var passIndex: Int
    public var phase: ErasePhase
    /// Blocks below this index are written and flushed for `passIndex`.
    public var nextBlock: UInt64
    /// The run key, encrypted by a `KeyWrapping`.
    public var wrappedKey: Data
    public var startedAt: Date
    public var updatedAt: Date
}

public protocol CheckpointStore {
    func load() throws -> Checkpoint?
    func save(_ checkpoint: Checkpoint) throws
    func clear() throws
}

public protocol KeyWrapping {
    func wrap(_ key: Data) throws -> Data
    func unwrap(_ wrapped: Data) throws -> Data
}

/// Checkpointing is optional. Without it a run cannot be resumed.
public struct Checkpointing {
    public var store: CheckpointStore
    public var wrapper: KeyWrapping
    public var deviceIdentity: String

    public init(store: CheckpointStore, wrapper: KeyWrapping, deviceIdentity: String) {
        self.store = store
        self.wrapper = wrapper
        self.deviceIdentity = deviceIdentity
    }
}

/// One JSON file, replaced atomically, readable by its owner only.
public final class FileCheckpointStore: CheckpointStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Checkpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Checkpoint.self, from: data)
    }

    public func save(_ checkpoint: Checkpoint) throws {
        let data = try JSONEncoder().encode(checkpoint)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// Encrypts the run key with ChaCha20-Poly1305 under a key-encryption key
/// kept in its own owner-only file. The checkpoint alone does not reveal the
/// run key.
public final class FileKeyWrapper: KeyWrapping {
    private let keyURL: URL

    public init(keyURL: URL) {
        self.keyURL = keyURL
    }

    public func wrap(_ key: Data) throws -> Data {
        try ChaChaPoly.seal(key, using: loadOrCreateKey()).combined
    }

    public func unwrap(_ wrapped: Data) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: wrapped), using: loadOrCreateKey())
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try FileManager.default.createDirectory(
            at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try key.withUnsafeBytes { Data($0) }.write(to: keyURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return key
    }
}
