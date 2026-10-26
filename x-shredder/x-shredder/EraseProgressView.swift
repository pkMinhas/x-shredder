import SwiftUI
import DiskGuard

struct EraseProgressView: View {
    @EnvironmentObject private var model: AppModel
    let disk: DiskDescription
    @State private var cancelRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Erasing \(disk.displayName)")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            if let progress = model.progress {
                Text(ProgressText.phase(progress))
                    .font(.headline)
                ProgressView(value: progress.fraction)
                    .accessibilityLabel("Erase progress")
                    .accessibilityValue("\(Int(progress.fraction * 100)) percent, \(ProgressText.phase(progress))")
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Speed").foregroundStyle(.secondary)
                        Text(ProgressText.speed(progress.bytesPerSecond)).monospacedDigit()
                    }
                    GridRow {
                        Text("Time remaining").foregroundStyle(.secondary)
                        Text(ProgressText.remaining(progress.secondsRemaining)).monospacedDigit()
                    }
                    GridRow {
                        Text("This phase").foregroundStyle(.secondary)
                        Text("\(SizeFormat.label(bytes: progress.phaseBytes)) of \(SizeFormat.label(bytes: progress.deviceBytes))")
                            .monospacedDigit()
                    }
                }
            } else {
                ProgressView()
                Text("Unmounting and checking the card again before writing")
                    .foregroundStyle(.secondary)
            }

            Text("Do not remove the card. Keep the Mac awake until this finishes.")
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button(cancelRequested ? "Cancelling" : "Cancel Erase") {
                    cancelRequested = true
                    model.cancelErase()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(cancelRequested)
                .accessibilityHint("Stops the erase. The card will be left partly overwritten.")
            }
        }
    }
}

enum ProgressText {
    static func phase(_ progress: EraseProgressMessage) -> String {
        let action: String
        switch (progress.phase, progress.pattern) {
        case ("write", "zero"): action = "Writing zeros"
        case ("write", _): action = "Writing random data"
        default: action = "Verifying"
        }
        return "Pass \(progress.passIndex + 1) of \(progress.passCount): \(action)"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "Measuring" }
        return String(format: "%.1f MB/s", locale: Locale(identifier: "en_US_POSIX"), bytesPerSecond / 1_000_000)
    }

    static func remaining(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "Estimating" }
        let total = Int(seconds.rounded(.up))
        if total >= 3600 { return "\(total / 3600) h \((total % 3600) / 60) min" }
        if total >= 60 { return "\(total / 60) min \(total % 60) s" }
        return "\(total) s"
    }
}
