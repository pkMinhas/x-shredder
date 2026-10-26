import Foundation
import DiskGuard

/// The text the user has to type before an erase can start.
enum ConfirmationPhrase {
    static func phrase(for disk: DiskDescription) -> String {
        "\(disk.sizeLabel) \(disk.displayName)"
    }

    /// Exact match. Only whitespace around the typed text is ignored.
    static func matches(_ typed: String, disk: DiskDescription) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == phrase(for: disk)
    }
}
