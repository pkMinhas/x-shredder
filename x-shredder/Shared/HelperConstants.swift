import Foundation
import DiskGuard

enum HelperConstants {
    static let appBundleID = "com.withpreet.x-shredder"
    static let helperBundleID = "com.withpreet.x-shredder.helper"
    static let machServiceName = "com.withpreet.x-shredder.helper"
    static let daemonPlistName = "com.withpreet.x-shredder.helper.plist"
}

extension Policy {
    /// The policy both the app and the helper use. Release builds get the
    /// standard policy and nothing else. Debug builds also accept small
    /// scratch disk images so the erase path can be tested without a card.
    static var active: Policy {
        var policy = Policy.standard
        #if DEBUG
        policy.allowTestDiskImages = true
        #endif
        return policy
    }

    static var allowsTestDiskImages: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
