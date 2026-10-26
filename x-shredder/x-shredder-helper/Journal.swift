import Foundation

/// Records what the helper is doing so that a crash mid-erase is reported as
/// a failure, never as a success and never as nothing.
final class Journal {
    struct Contents: Codable {
        /// Set before the device is touched, cleared when the run ends.
        var active: EraseResult?
        var lastResult: EraseResult?
    }

    static let directory = URL(fileURLWithPath: "/Library/Application Support/com.withpreet.x-shredder", isDirectory: true)

    private let url: URL
    private let lock = NSLock()
    private var contents = Contents()

    init(directory: URL = Journal.directory) {
        url = directory.appendingPathComponent("journal.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Contents.self, from: data) {
            contents = saved
        }
    }

    var lastResult: EraseResult? {
        lock.lock()
        defer { lock.unlock() }
        return contents.lastResult
    }

    /// Called at launch. A run still marked active means the helper died
    /// while erasing.
    func recoverAfterCrash() {
        lock.lock()
        defer { lock.unlock() }
        guard var interrupted = contents.active else { return }
        interrupted.succeeded = false
        interrupted.verification = "notCompleted"
        interrupted.finishedAt = Date()
        interrupted.errors = ["The helper stopped while the erase was running. The erase did not complete."]
        contents.active = nil
        contents.lastResult = interrupted
        save()
        Log.helper.error("Previous erase of \(interrupted.bsdName, privacy: .public) was interrupted, recorded as failed")
    }

    /// `provisional` is stored as a failed result until `finish` replaces it.
    func begin(_ provisional: EraseResult) throws {
        lock.lock()
        defer { lock.unlock() }
        contents.active = provisional
        guard save() else { throw CocoaError(.fileWriteUnknown) }
    }

    func finish(_ result: EraseResult) {
        lock.lock()
        defer { lock.unlock() }
        contents.active = nil
        contents.lastResult = result
        save()
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(contents).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            Log.helper.error("Could not write the journal: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
