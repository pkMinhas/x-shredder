import Foundation
import DiskGuard

/// What the app may ask the helper to do. Disks are named by BSD name only.
/// There is no path argument and no flag that relaxes a check.
@objc protocol EraseHelperProtocol {
    /// Replies with a JSON `HelperStatus`.
    func status(reply: @escaping (Data) -> Void)
    /// Replies with a JSON array of `DiskDescription`, eligible disks only,
    /// as judged by the helper from fresh data.
    func listEligibleDisks(reply: @escaping (Data) -> Void)
    /// `options` is a JSON `EraseOptions`. Replies with `nil` when the erase
    /// was accepted and started, or a refusal message.
    func startErase(bsdName: String, options: Data, reply: @escaping (String?) -> Void)
    func cancel(reply: @escaping () -> Void)
}

/// Callbacks from the helper to the app.
@objc protocol EraseClientProtocol {
    /// JSON `EraseProgressMessage`.
    func eraseProgress(_ data: Data)
    /// JSON `EraseResult`.
    func eraseFinished(_ data: Data)
}

struct EraseOptions: Codable, Equatable {
    /// Add a second pass of zeros after the random pass.
    var zeroPass: Bool

    static let maxEncodedBytes = 256

    /// Strict decoding: exactly the known keys, nothing else.
    static func decodeStrict(_ data: Data) -> EraseOptions? {
        guard data.count <= maxEncodedBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["zeroPass"],
              let value = object["zeroPass"] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return EraseOptions(zeroPass: value.boolValue)
    }
}

struct EraseProgressMessage: Codable, Equatable {
    var bsdName: String
    var passIndex: Int
    var passCount: Int
    /// "random" or "zero"
    var pattern: String
    /// "write" or "verify"
    var phase: String
    var phaseBytes: UInt64
    var deviceBytes: UInt64
    var fraction: Double
    var bytesPerSecond: Double
    var secondsRemaining: Double?
}

struct EraseResult: Codable, Equatable, Identifiable {
    var id: UUID
    var bsdName: String
    var succeeded: Bool
    var cancelled: Bool
    /// "passed", "failed" or "notCompleted"
    var verification: String
    var passes: [String]
    var passesVerified: Int
    var errors: [String]
    var deviceModel: String
    var deviceSizeBytes: UInt64
    var serialNumber: String?
    var startedAt: Date
    var finishedAt: Date
    var resumed: Bool
    var helperVersion: String
}

struct HelperStatus: Codable, Equatable {
    var version: String
    var isErasing: Bool
    var activeBSDName: String?
    var lastProgress: EraseProgressMessage?
    /// The most recent finished run, including one that ended because the
    /// helper stopped.
    var lastResult: EraseResult?
    var allowsTestDiskImages: Bool
}

enum Wire {
    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
