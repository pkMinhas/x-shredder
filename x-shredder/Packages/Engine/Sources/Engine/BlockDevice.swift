import Foundation

/// A device addressed in fixed-size blocks. All I/O is in whole blocks.
public protocol BlockDevice: AnyObject {
    var blockSize: Int { get }
    var blockCount: UInt64 { get }

    /// Writes `buffer` (a whole number of blocks) starting at `block`.
    func write(_ buffer: UnsafeRawBufferPointer, atBlock block: UInt64) throws
    /// Fills `buffer` (a whole number of blocks) starting at `block`.
    func read(into buffer: UnsafeMutableRawBufferPointer, atBlock block: UInt64) throws
    /// Commits everything written so far to the media.
    func flush() throws
    /// Makes sure later reads come from the media, not from a cache.
    func dropCaches() throws
}

public struct DeviceIOError: Error, Equatable, CustomStringConvertible {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }

    public var description: String {
        "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
    }
}
