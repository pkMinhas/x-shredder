import os

/// Unified logging for the Engine.
///
/// No-secrets rule: the run key, the key-encryption key and any data read
/// from or written to a device must never appear in a log message. Log block
/// indexes, byte counts, phases and error codes only.
enum Log {
    static let engine = Logger(subsystem: "com.withpreet.x-shredder", category: "Engine")
}
