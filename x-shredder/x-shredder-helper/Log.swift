import os

/// Unified logging for the helper.
///
/// No-secrets rule: never log key material or device contents. Disk
/// identifiers, sizes, phases and error text are fine.
enum Log {
    static let helper = Logger(subsystem: "com.withpreet.x-shredder", category: "Helper")
}
