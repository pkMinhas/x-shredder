import Foundation
import Report

/// Every user-facing sentence about risk, method and limits, in one place so
/// the wording can be reviewed as a unit.
enum Wording {
    static let dataLossWarning =
        "Everything on this card will be destroyed. Photos, videos and files cannot be recovered afterwards. This cannot be undone."
    static let confirmInstruction = "To confirm, type the size and name of the card exactly as shown:"
    static let eraseButton = "Erase Card"

    static let methodVerified = ReportWording.methodLabelVerified
    static let methodNotVerified = ReportWording.methodLabelNotVerified
    static let limits = ReportWording.limitsStatement

    static let verificationAlwaysOn = "Every pass is read back and checked. This cannot be turned off."
    static let zeroPassOption = "Add a second pass of zeros"
    static let defaultPassDescription = "One pass of random data"

    static let noEligibleDisks = "No erasable card found. Insert an SD card in the built-in SD card slot or a USB card reader."
    static let excludedExplanation = "These disks can never be erased by this app."

    static let helperNeeded =
        "Erasing needs a helper that runs with administrator rights. Install it, then approve it in System Settings under Login Items."
    static let helperNeedsApproval =
        "The helper is installed but not yet approved. Open System Settings, go to General, Login Items, and allow x-shredder."

    static let debugBanner = "Debug build: small scratch disk images are selectable for testing."
}
