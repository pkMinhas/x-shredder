import SwiftUI
import DiskGuard

struct ConfirmationView: View {
    @EnvironmentObject private var model: AppModel
    let disk: DiskDescription
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var phrase: String { ConfirmationPhrase.phrase(for: disk) }
    private var matches: Bool { ConfirmationPhrase.matches(typed, disk: disk) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Erase this card?")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            GroupBox {
                DiskRow(entry: DiskEntry(disk: disk, eligibility: .eligible))
            }

            Label {
                Text(Wording.dataLossWarning)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Method: \(Wording.methodVerified)")
                Text(model.zeroPass ? "Passes: random data, then zeros" : "Passes: random data")
                Text(Wording.limits)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(Wording.confirmInstruction)
                Text(phrase)
                    .font(.system(.body, design: .monospaced).bold())
                    .textSelection(.disabled)
                    .accessibilityLabel("Text to type: \(phrase)")
                TextField("Size and name", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .disableAutocorrection(true)
                    .accessibilityLabel("Confirmation text")
                    .accessibilityHint("Type \(phrase) to enable the erase button")
            }

            Spacer()

            HStack {
                Button("Cancel") { model.backToDevices() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.isStarting { ProgressView().controlSize(.small) }
                // Deliberately not the default button: Return must not erase.
                Button(Wording.eraseButton, role: .destructive) {
                    model.erase(disk, typedConfirmation: typed)
                }
                .disabled(!matches || model.isStarting)
                .accessibilityHint("Destroys all data on \(disk.displayName)")
            }
        }
        .onAppear { fieldFocused = true }
    }
}
