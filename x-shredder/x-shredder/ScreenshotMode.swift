#if SCREENSHOTS
// Screenshot builds only. Compiled in only when SCREENSHOTS is set, which
// scripts/screenshots.sh does. Debug and Release builds never contain this.
//
// The app shows each scene with sample data, captures its own window and
// writes PNGs to build/screenshots/raw, then quits. No card or helper needed.

import AppKit
import DiskGuard

enum ScreenshotScene: String, CaseIterable {
    case devices, confirm, erasing, result
}

enum ScreenshotSamples {
    /// A card in the built-in SD card slot.
    static let card: DiskDescription = {
        var d = DiskDescription(bsdName: "disk4")
        d.isWhole = true
        d.isInternal = true
        d.protocolName = "Secure Digital"
        d.isRemovable = true
        d.isEjectable = true
        d.isWritable = true
        d.mediaSize = 127_865_454_592
        d.deviceVendor = "APPLE"
        d.deviceModel = "SD Card Reader"
        d.mediaName = "APPLE SD Card Reader Media"
        d.registryEntryID = 0x1000_0042
        d.serialNumber = "000000009C4A21F7"
        d.volumeNames = ["NO NAME"]
        return d
    }()

    /// A card in a USB card reader.
    static let usbCard: DiskDescription = {
        var d = DiskDescription(bsdName: "disk6")
        d.isWhole = true
        d.isInternal = false
        d.protocolName = "USB"
        d.isRemovable = true
        d.isEjectable = true
        d.isWritable = true
        d.mediaSize = 63_864_569_856
        d.deviceVendor = "Generic"
        d.deviceModel = "STORAGE DEVICE"
        d.mediaName = "Generic STORAGE DEVICE Media"
        d.registryEntryID = 0x1000_0077
        d.volumeNames = ["CAMERA"]
        return d
    }()

    static let internalSSD: DiskDescription = {
        var d = DiskDescription(bsdName: "disk0")
        d.isWhole = true
        d.isInternal = true
        d.protocolName = "Apple Fabric"
        d.isRemovable = false
        d.isEjectable = false
        d.isWritable = true
        d.mediaSize = 1_000_555_581_440
        d.deviceVendor = "APPLE"
        d.deviceModel = "SSD AP1024Z"
        d.hasMediaAncestor = false
        d.volumeNames = ["Macintosh HD"]
        return d
    }()

    static let diskImage: DiskDescription = {
        var d = DiskDescription(bsdName: "disk8")
        d.isWhole = true
        d.isInternal = false
        d.protocolName = "Disk Image"
        d.isRemovable = true
        d.isEjectable = true
        d.isWritable = false
        d.mediaSize = 524_288_000
        d.deviceVendor = "Apple"
        d.deviceModel = "Disk Image"
        d.volumeNames = ["Installer"]
        return d
    }()

    /// Cards are shown as eligible. Excluded disks go through the real rules,
    /// so the reasons shown are the app's own.
    static var entries: [DiskEntry] {
        let context = SystemContext(protectedWholeDisks: ["disk0"])
        let excluded = [internalSSD, diskImage].map {
            DiskEntry(disk: $0, eligibility: DiskGuard.evaluate($0, context: context, policy: Policy.active))
        }
        return [DiskEntry(disk: card, eligibility: .eligible), DiskEntry(disk: usbCard, eligibility: .eligible)] + excluded
    }

    /// Pass 1 of 2, verifying, 62% through the phase. Same math as the engine.
    static var progress: EraseProgressMessage {
        let device = Double(card.mediaSize!)
        let phaseBytes = device * 0.62
        let total = device * 2 * 2
        let done = device + phaseBytes
        let rate = 91_400_000.0
        return EraseProgressMessage(
            bsdName: card.bsdName, passIndex: 0, passCount: 2, pattern: "random", phase: "verify",
            phaseBytes: UInt64(phaseBytes), deviceBytes: card.mediaSize!, fraction: done / total,
            bytesPerSecond: rate, secondsRemaining: (total - done) / rate)
    }

    static var result: EraseResult {
        let finished = Date()
        return EraseResult(
            id: UUID(), bsdName: card.bsdName, succeeded: true, cancelled: false,
            verification: "passed", passes: ["random", "zero"], passesVerified: 2, errors: [],
            deviceModel: card.displayName, deviceSizeBytes: card.mediaSize!,
            serialNumber: card.serialNumber, startedAt: finished.addingTimeInterval(-5_620),
            finishedAt: finished, resumed: false, helperVersion: "1.0")
    }
}

@MainActor
enum ScreenshotDriver {
    /// The card list needs room for every row. The other screens are short.
    static func contentSize(for scene: ScreenshotScene) -> NSSize {
        NSSize(width: 720, height: scene == .devices ? 690 : 540)
    }

    /// Repository root, from this file's location.
    static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // app sources
            .deletingLastPathComponent()   // project folder
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("build/screenshots/raw", isDirectory: true)
    }

    static func run(_ model: AppModel) async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            print("screenshots: no window")
            NSApp.terminate(nil)
            return
        }
        window.makeKeyAndOrderFront(nil)

        for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearanceName)
            for (index, scene) in ScreenshotScene.allCases.enumerated() {
                window.setContentSize(contentSize(for: scene))
                window.center()
                model.applyScreenshotScene(scene)
                try? await Task.sleep(nanoseconds: 700_000_000)
                if scene == .confirm {
                    // Type the confirmation phrase into the focused field.
                    let phrase = ConfirmationPhrase.phrase(for: ScreenshotSamples.card)
                    (window.firstResponder as? NSTextView)?.insertText(phrase, replacementRange: NSRange(location: NSNotFound, length: 0))
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                let name = "\(index + 1)-\(scene.rawValue)-\(suffix).png"
                capture(window, to: outputDirectory.appendingPathComponent(name))
            }
        }
        print("screenshots: wrote \(outputDirectory.path)")
        NSApp.terminate(nil)
    }

    /// Draws the whole window, title bar included, at the screen's scale.
    private static func capture(_ window: NSWindow, to url: URL) {
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
}
#endif
