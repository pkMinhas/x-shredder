import Foundation
import CDiskIO

/// A raw disk device (`/dev/rdiskN`).
///
/// Raw character devices bypass the kernel buffer cache. `F_NOCACHE` is set
/// as well so nothing is cached if the node is ever a block device.
public final class RawBlockDevice: BlockDevice {
    public let blockSize: Int
    public let blockCount: UInt64
    private let fd: Int32
    private let ownsDescriptor: Bool

    /// Wraps a descriptor that is already open for reading and writing.
    public init(fileDescriptor: Int32, ownsDescriptor: Bool) throws {
        fd = fileDescriptor
        self.ownsDescriptor = ownsDescriptor

        var size: UInt32 = 0
        var count: UInt64 = 0
        guard xs_disk_block_size(fd, &size) == 0 else {
            let code = errno
            if ownsDescriptor { close(fd) }
            throw DeviceIOError(operation: "DKIOCGETBLOCKSIZE", code: code)
        }
        guard xs_disk_block_count(fd, &count) == 0 else {
            let code = errno
            if ownsDescriptor { close(fd) }
            throw DeviceIOError(operation: "DKIOCGETBLOCKCOUNT", code: code)
        }
        guard size > 0, count > 0 else {
            if ownsDescriptor { close(fd) }
            throw DeviceIOError(operation: "geometry", code: EINVAL)
        }
        guard fcntl(fd, F_NOCACHE, 1) == 0 else {
            let code = errno
            if ownsDescriptor { close(fd) }
            throw DeviceIOError(operation: "F_NOCACHE", code: code)
        }
        blockSize = Int(size)
        blockCount = count
    }

    /// Opens a raw device node exclusively. Used by tests against disk
    /// images. The helper gets its descriptor from DiskGuard instead.
    public convenience init(path: String) throws {
        let fd = open(path, O_RDWR | O_EXLOCK | O_NONBLOCK)
        guard fd >= 0 else { throw DeviceIOError(operation: "open", code: errno) }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        try self.init(fileDescriptor: fd, ownsDescriptor: true)
    }

    deinit {
        if ownsDescriptor { close(fd) }
    }

    public func write(_ buffer: UnsafeRawBufferPointer, atBlock block: UInt64) throws {
        var done = 0
        while done < buffer.count {
            let offset = off_t(block) * off_t(blockSize) + off_t(done)
            let result = pwrite(fd, buffer.baseAddress! + done, buffer.count - done, offset)
            if result < 0 {
                if errno == EINTR { continue }
                throw DeviceIOError(operation: "write", code: errno)
            }
            guard result > 0, result % blockSize == 0 else {
                throw DeviceIOError(operation: "write", code: EIO)
            }
            done += result
        }
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer, atBlock block: UInt64) throws {
        var done = 0
        while done < buffer.count {
            let offset = off_t(block) * off_t(blockSize) + off_t(done)
            let result = pread(fd, buffer.baseAddress! + done, buffer.count - done, offset)
            if result < 0 {
                if errno == EINTR { continue }
                throw DeviceIOError(operation: "read", code: errno)
            }
            guard result > 0, result % blockSize == 0 else {
                throw DeviceIOError(operation: "read", code: EIO)
            }
            done += result
        }
    }

    /// `F_FULLFSYNC` first. Raw device nodes answer it with ENOTTY, in which
    /// case `DKIOCSYNCHRONIZE` is sent, which is the request F_FULLFSYNC
    /// turns into at the device.
    public func flush() throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        let code = errno
        guard code == ENOTTY || code == ENOTSUP || code == EINVAL else {
            throw DeviceIOError(operation: "F_FULLFSYNC", code: code)
        }
        guard xs_disk_synchronize(fd) == 0 else {
            throw DeviceIOError(operation: "DKIOCSYNCHRONIZE", code: errno)
        }
    }

    /// Raw device reads are unbuffered, so once the device has committed its
    /// write cache the next read comes from the media.
    public func dropCaches() throws {
        try flush()
    }
}
