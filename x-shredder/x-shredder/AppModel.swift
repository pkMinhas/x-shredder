import Foundation
import Combine
import DiskGuard
import Report

struct DiskEntry: Identifiable, Equatable {
    var disk: DiskDescription
    var eligibility: Eligibility

    var id: String { disk.bsdName }
    var isEligible: Bool { eligibility.isEligible }
    /// The reason shown in the greyed-out list. A definite reason ("Internal
    /// disk") is preferred over an unreadable key ("Could not tell...").
    var exclusionReason: String? {
        let failures = eligibility.failures
        return (failures.first { !$0.reason.hasPrefix("Could not") } ?? failures.first)?.reason
    }
}

enum Screen: Equatable {
    case devices
    case confirm(DiskDescription)
    case erasing(DiskDescription)
    case result(EraseResult)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var entries: [DiskEntry] = []
    @Published var selection: String?
    @Published var showExcluded = false
    @Published var zeroPass = false
    @Published private(set) var screen = Screen.devices
    @Published private(set) var helperState = HelperInstallState.notRegistered
    @Published private(set) var progress: EraseProgressMessage?
    @Published private(set) var signedReport: SignedReport?
    @Published private(set) var isStarting = false
    @Published var alertMessage: String?

    private let helper = HelperClient()
    private let source = LiveDiskSource()
    private let policy = Policy.active
    private var monitor: DiskMonitor?
    private var refreshTask: Task<Void, Never>?

    var eligibleEntries: [DiskEntry] { entries.filter(\.isEligible) }
    var excludedEntries: [DiskEntry] { entries.filter { !$0.isEligible } }
    var selectedDisk: DiskDescription? { eligibleEntries.first { $0.id == selection }?.disk }
    var allowsTestDiskImages: Bool { Policy.allowsTestDiskImages }

    init() {
        helper.onProgress = { [weak self] message in
            Task { @MainActor [weak self] in self?.progress = message }
        }
        helper.onFinished = { [weak self] result in
            Task { @MainActor [weak self] in self?.finish(with: result) }
        }
        helper.onDisconnected = { [weak self] in
            Task { @MainActor [weak self] in self?.helperDisconnected() }
        }
    }

    // MARK: Start-up

    func start() {
        guard monitor == nil else { return }
        monitor = DiskMonitor { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        refreshDisks()
        refreshHelperState()
        Task { await reattachIfErasing() }
    }

    /// If the app was closed during an erase, pick the run up again.
    private func reattachIfErasing() async {
        guard helperState == .enabled, let status = try? await helper.status() else { return }
        if status.isErasing, let name = status.activeBSDName, screen == .devices {
            let disk = entries.first { $0.id == name }?.disk ?? DiskDescription(bsdName: name)
            progress = status.lastProgress
            screen = .erasing(disk)
        }
    }

    // MARK: Disks

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            // Arrival of one card produces a burst of callbacks.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshDisks()
        }
    }

    func refreshDisks() {
        let snapshot = source.snapshot()
        entries = snapshot.disks.map {
            DiskEntry(disk: $0, eligibility: DiskGuard.evaluate($0, context: snapshot.context, policy: policy))
        }
        // A selection can only ever name an eligible disk.
        if let selection, !eligibleEntries.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        if case .confirm(let disk) = screen, !isStillEligible(disk) {
            screen = .devices
            alertMessage = "The selected card was removed or changed."
        }
    }

    private func isStillEligible(_ disk: DiskDescription) -> Bool {
        eligibleEntries.contains { $0.disk.bsdName == disk.bsdName && $0.disk.registryEntryID == disk.registryEntryID }
    }

    // MARK: Helper

    func refreshHelperState() {
        helperState = helper.installState
    }

    func installHelper() {
        do {
            try helper.register()
        } catch {
            // Registration reports "needs approval" as an error. The state
            // below shows the user what to do next.
            if helper.installState != .requiresApproval {
                alertMessage = "Could not install the helper: \(error.localizedDescription)"
            }
        }
        refreshHelperState()
    }

    func uninstallHelper() {
        Task {
            do {
                try await helper.unregister()
            } catch {
                alertMessage = "Could not remove the helper: \(error.localizedDescription)"
            }
            refreshHelperState()
        }
    }

    func openLoginItems() {
        HelperClient.openLoginItemsSettings()
    }

    // MARK: Flow

    func continueToConfirmation() {
        guard let disk = selectedDisk else { return }
        screen = .confirm(disk)
    }

    func backToDevices() {
        screen = .devices
        progress = nil
        signedReport = nil
        refreshDisks()
        refreshHelperState()
    }

    func erase(_ disk: DiskDescription, typedConfirmation: String) {
        guard ConfirmationPhrase.matches(typedConfirmation, disk: disk), !isStarting else { return }
        refreshDisks()
        guard isStillEligible(disk) else { return }
        isStarting = true
        let options = EraseOptions(zeroPass: zeroPass)
        Task {
            defer { isStarting = false }
            do {
                // The helper's own list has to agree before we even ask.
                let helperDisks = try await helper.eligibleDisks()
                guard helperDisks.contains(where: { $0.bsdName == disk.bsdName && $0.registryEntryID == disk.registryEntryID }) else {
                    alertMessage = "The helper does not consider this disk erasable. Nothing was changed."
                    screen = .devices
                    return
                }
                if let refusal = try await helper.startErase(bsdName: disk.bsdName, options: options) {
                    alertMessage = "The helper refused to erase this disk: \(refusal). Nothing was changed."
                    screen = .devices
                    return
                }
                progress = nil
                screen = .erasing(disk)
            } catch {
                alertMessage = error.localizedDescription
                refreshHelperState()
            }
        }
    }

    func cancelErase() {
        Task {
            do {
                try await helper.cancel()
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func finish(with result: EraseResult) {
        guard case .erasing = screen else { return }
        show(result)
    }

    private func show(_ result: EraseResult) {
        do {
            signedReport = try ReportBuilder.signedReport(
                from: result, keyStore: KeychainSigningKeyStore(service: ReportBuilder.keychainService))
        } catch {
            signedReport = nil
            alertMessage = "The report could not be signed, so it cannot be exported: \(error)"
        }
        screen = .result(result)
        refreshDisks()
    }

    /// The helper went away. If an erase was running, ask a fresh helper
    /// what happened. Its journal records an interrupted run as failed.
    private func helperDisconnected() {
        guard case .erasing(let disk) = screen else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard case .erasing = screen else { return }
            if let status = try? await helper.status() {
                if status.isErasing { return }
                if let last = status.lastResult, last.bsdName == disk.bsdName {
                    show(last)
                    return
                }
            }
            show(EraseResult(
                id: UUID(), bsdName: disk.bsdName, succeeded: false, cancelled: false,
                verification: "notCompleted", passes: [], passesVerified: 0,
                errors: ["Lost contact with the helper. The erase did not complete."],
                deviceModel: disk.displayName, deviceSizeBytes: disk.mediaSize ?? 0,
                serialNumber: disk.serialNumber, startedAt: Date(), finishedAt: Date(),
                resumed: false, helperVersion: "unknown"))
        }
    }
}
