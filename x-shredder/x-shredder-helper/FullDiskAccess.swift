import Foundation

/// macOS refuses to let a process open a raw disk until it has Full Disk
/// Access, even when it runs as root. The open fails with EPERM.
enum FullDiskAccess {
    /// A file macOS protects behind Full Disk Access, present on every Mac.
    static let probePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// `true` when the probe file can be opened, `false` when macOS refuses
    /// with EPERM, `nil` for any other outcome.
    static func check() -> Bool? {
        let fd = open(probePath, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return errno == EPERM ? false : nil
    }
}
