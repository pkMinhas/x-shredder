import Foundation
import DiskGuard

// Prints every whole disk, the media topology and the mounts as JSON, plus
// the verdict of the standard policy. Read-only.

struct Dump: Encodable {
    struct Entry: Encodable {
        var description: DiskDescription
        var eligible: Bool
        var failures: [RuleFailure]
    }
    var disks: [Entry]
    var protectedWholeDisks: [String]?
    var nodes: [MediaNode]
    var mounts: [Mount]
}

let snapshot = LiveDiskSource().snapshot()
let dump = Dump(
    disks: snapshot.disks.map { disk in
        let eligibility = DiskGuard.evaluate(disk, context: snapshot.context, policy: .standard)
        return Dump.Entry(description: disk, eligible: eligibility.isEligible, failures: eligibility.failures)
    },
    protectedWholeDisks: snapshot.context.protectedWholeDisks?.sorted(),
    nodes: snapshot.nodes,
    mounts: snapshot.mounts
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(dump))
FileHandle.standardOutput.write(Data("\n".utf8))
