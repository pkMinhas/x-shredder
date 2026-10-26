import os

/// Unified logging for DiskGuard.
///
/// No-secrets rule: never log key material, file contents or device data.
/// Disk identifiers (BSD name, model, size, protocol) are fine. Serial numbers
/// are logged as private.
enum Log {
    static let guardLog = Logger(subsystem: "com.withpreet.x-shredder", category: "DiskGuard")
}
