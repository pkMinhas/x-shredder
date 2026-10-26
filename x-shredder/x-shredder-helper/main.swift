import Foundation
import DiskGuard

// Privileged helper. Runs as a launch daemon, registered by the app through
// SMAppService. It accepts a BSD name and options, re-validates the disk
// itself, and performs the erase.

Log.helper.info("Helper \(EraseCoordinator.version, privacy: .public) starting")
#if DEBUG
Log.helper.notice("Debug build: \(Policy.testDiskImageMarker, privacy: .public)")
#endif

// Only the app, signed by the same team as this helper, may connect. A build
// with no team identifier (unsigned or ad-hoc) has nothing to pin, so it
// refuses to serve at all.
guard let requirement = PeerRequirement.requirement(forIdentifier: HelperConstants.appBundleID) else {
    Log.helper.fault("No team identifier in the helper's signature. Refusing to accept connections.")
    exit(EXIT_FAILURE)
}

let journal = Journal()
journal.recoverAfterCrash()

let coordinator = EraseCoordinator(journal: journal)
let delegate = ListenerDelegate(coordinator: coordinator)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
listener.resume()

dispatchMain()
