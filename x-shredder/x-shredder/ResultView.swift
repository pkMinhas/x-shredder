import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiskGuard
import Report

struct ResultView: View {
    @EnvironmentObject private var model: AppModel
    let result: EraseResult

    private var methodLabel: String {
        result.succeeded && result.verification == "passed" ? Wording.methodVerified : Wording.methodNotVerified
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(result.succeeded ? "Erase succeeded" : (result.cancelled ? "Erase cancelled" : "Erase failed"))
                    .font(.title2.bold())
            } icon: {
                Image(systemName: result.succeeded ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.succeeded ? .green : .red)
                    .font(.title)
            }
            .accessibilityAddTraits(.isHeader)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Method", methodLabel)
                row("Card", "\(result.deviceModel), \(SizeFormat.label(bytes: result.deviceSizeBytes))")
                row("Serial number", result.serialNumber ?? "Not available")
                row("Passes", result.passes.isEmpty ? "None" : result.passes.joined(separator: ", "))
                row("Verified", "\(result.passesVerified) of \(result.passes.count) passes")
                if result.resumed { row("Note", "Continued from an interrupted run") }
            }

            if !result.errors.isEmpty {
                GroupBox("What went wrong") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.errors, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            if !result.succeeded {
                Text("Do not treat this card as erased.")
                    .font(.headline)
            }

            Text(Wording.limits)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Button("Export PDF") { export(type: .pdf) }
                    .disabled(model.signedReport == nil)
                Button("Export JSON") { export(type: .json) }
                    .disabled(model.signedReport == nil)
                Spacer()
                Button("Done") { model.backToDevices() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func export(type: UTType) {
        guard let signed = model.signedReport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let stamp = ISO8601DateFormatter().string(from: result.finishedAt).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "erase-report-\(stamp).\(type == .pdf ? "pdf" : "json")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = type == .pdf ? ReportExporter.pdf(signed) : try ReportExporter.json(signed)
            try data.write(to: url, options: .atomic)
        } catch {
            model.alertMessage = "Could not save the report: \(error.localizedDescription)"
        }
    }
}
