import SwiftUI
import DiskGuard

struct DeviceListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a card to erase")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            if model.allowsTestDiskImages {
                Label(Wording.debugBanner, systemImage: "hammer")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HelperStatusView()

            List(selection: $model.selection) {
                Section("Erasable cards") {
                    if model.eligibleEntries.isEmpty {
                        Text(Wording.noEligibleDisks)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.eligibleEntries) { entry in
                        DiskRow(entry: entry)
                            .tag(entry.id)
                    }
                }
                if model.showExcluded {
                    Section {
                        // No tag: these rows cannot become the selection.
                        ForEach(model.excludedEntries) { entry in
                            DiskRow(entry: entry)
                                .selectionDisabled()
                        }
                    } header: {
                        Text("Excluded disks")
                    } footer: {
                        Text(Wording.excludedExplanation)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .accessibilityLabel("Disks")

            Toggle("Show excluded disks", isOn: $model.showExcluded)

            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 6) {
                    Label(Wording.defaultPassDescription, systemImage: "checkmark.circle")
                    Toggle(Wording.zeroPassOption, isOn: $model.zeroPass)
                    Label(Wording.verificationAlwaysOn, systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Continue") { model.continueToConfirmation() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedDisk == nil || model.helperState != .enabled || model.helperNeedsFullDiskAccess)
                    .accessibilityHint("Goes to the confirmation step. Nothing is erased yet.")
            }
        }
    }
}

private extension View {
    /// Excluded rows are visible but inert.
    func selectionDisabled() -> some View {
        self.disabled(true).allowsHitTesting(false)
    }
}

struct DiskRow: View {
    let entry: DiskEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isEligible ? "sdcard" : "nosign")
                .font(.title2)
                .foregroundStyle(entry.isEligible ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.disk.displayName)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let reason = entry.exclusionReason {
                    Text("Excluded: \(reason)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(entry.disk.sizeLabel)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .opacity(entry.isEligible ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var detail: String {
        var parts = [entry.disk.protocolName ?? "Unknown connection", entry.disk.bsdName]
        if let media = entry.disk.mediaName, !media.isEmpty { parts.append(media) }
        if !entry.disk.volumeNames.isEmpty {
            parts.append("Volumes: " + entry.disk.volumeNames.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var text = "\(entry.disk.displayName), \(entry.disk.sizeLabel), \(entry.disk.protocolName ?? "unknown connection")"
        if !entry.disk.volumeNames.isEmpty { text += ", volumes \(entry.disk.volumeNames.joined(separator: ", "))" }
        if let reason = entry.exclusionReason { text += ". Excluded: \(reason). Cannot be selected." }
        return text
    }
}

struct HelperStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.helperState {
        case .enabled where model.helperNeedsFullDiskAccess:
            banner(Wording.helperNeedsFullDiskAccess) {
                Button("Open Full Disk Access") { model.openFullDiskAccess() }
                    .accessibilityHint("Opens System Settings and shows the helper in Finder.")
            }
        case .enabled:
            EmptyView()
        case .requiresApproval:
            banner(Wording.helperNeedsApproval) {
                Button("Open Login Items") { model.openLoginItems() }
            }
        case .notRegistered, .notFound:
            banner(Wording.helperNeeded) {
                Button("Install Helper") { model.installHelper() }
            }
        }
    }

    private func banner(_ text: String, @ViewBuilder action: () -> some View) -> some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                action()
            }
            .padding(4)
        }
    }
}
