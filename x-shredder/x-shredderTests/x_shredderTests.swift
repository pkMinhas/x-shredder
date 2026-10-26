//
//  x_shredderTests.swift
//  x-shredderTests
//
//  Created by Preet Minhas on 13/10/26.
//

import Foundation
import Testing
import DiskGuard
import Report
@testable import x_shredder

struct x_shredderTests {

    private func card() -> DiskDescription {
        var disk = DiskDescription(bsdName: "disk4")
        disk.deviceVendor = "Generic"
        disk.deviceModel = "STORAGE DEVICE"
        disk.mediaSize = 31_914_983_424
        return disk
    }

    private func result(succeeded: Bool, verification: String) -> EraseResult {
        EraseResult(
            id: UUID(), bsdName: "disk4", succeeded: succeeded, cancelled: false,
            verification: verification, passes: ["random"], passesVerified: succeeded ? 1 : 0,
            errors: succeeded ? [] : ["Verification failed"], deviceModel: "Generic STORAGE DEVICE",
            deviceSizeBytes: 31_914_983_424, serialNumber: nil,
            startedAt: Date(timeIntervalSince1970: 1), finishedAt: Date(timeIntervalSince1970: 2),
            resumed: false, helperVersion: "1.0 (1)")
    }

    // MARK: Confirmation step

    @Test func confirmationNeedsTheExactSizeAndName() {
        let disk = card()
        #expect(ConfirmationPhrase.phrase(for: disk) == "31.9 GB Generic STORAGE DEVICE")
        #expect(ConfirmationPhrase.matches("31.9 GB Generic STORAGE DEVICE", disk: disk))
        #expect(ConfirmationPhrase.matches("  31.9 GB Generic STORAGE DEVICE\n", disk: disk))
        for wrong in ["", "31.9 GB", "Generic STORAGE DEVICE", "31.9 gb generic storage device",
                      "32 GB Generic STORAGE DEVICE", "31.9 GB  Generic STORAGE DEVICE", "31.9GB Generic STORAGE DEVICE"] {
            #expect(!ConfirmationPhrase.matches(wrong, disk: disk))
        }
    }

    // MARK: Options sent to the helper

    @Test func optionsDecodeStrictly() {
        #expect(EraseOptions.decodeStrict(Wire.encode(EraseOptions(zeroPass: true))) == EraseOptions(zeroPass: true))
        #expect(EraseOptions.decodeStrict(Data(#"{"zeroPass":false}"#.utf8)) == EraseOptions(zeroPass: false))
        // Unknown keys, wrong types and anything that smells like an override are refused.
        for bad in [#"{}"#, #"{"zeroPass":1}"#, #"{"zeroPass":"true"}"#, #"{"zeroPass":true,"force":true}"#,
                    #"{"zeroPass":true,"path":"/dev/rdisk0"}"#, #"{"zeroPass":true,"skipVerification":true}"#,
                    #"[true]"#, #"not json"#, ""] {
            #expect(EraseOptions.decodeStrict(Data(bad.utf8)) == nil)
        }
        let oversized = #"{"zeroPass":true,"padding":""# + String(repeating: "x", count: 400) + #""}"#
        #expect(EraseOptions.decodeStrict(Data(oversized.utf8)) == nil)
    }

    // MARK: Report mapping

    @Test func reportUsesTheHonestMethodLabel() {
        let ok = ReportBuilder.report(from: result(succeeded: true, verification: "passed"))
        #expect(ok.methodLabel == "Clear via overwrite, verified")
        #expect(ok.verification == .passed)
        #expect(ok.deviceSizeBytes == 31_914_983_424)

        let failed = ReportBuilder.report(from: result(succeeded: false, verification: "failed"))
        #expect(failed.methodLabel == "Clear via overwrite, not verified")
        #expect(failed.errors == ["Verification failed"])

        let unknown = ReportBuilder.report(from: result(succeeded: false, verification: "something else"))
        #expect(unknown.verification == .notCompleted)
        #expect(!unknown.limitsStatement.isEmpty)
    }

    @Test func signedReportVerifies() throws {
        let signed = try ReportBuilder.signedReport(
            from: result(succeeded: true, verification: "passed"), keyStore: InMemorySigningKeyStore())
        #expect(ReportSigner.verify(signed))
    }

    // MARK: Caller check

    @Test func peerRequirementPinsIdentifierAndTeam() {
        let requirement = PeerRequirement.requirement(forIdentifier: "com.withpreet.x-shredder", team: "ABCDE12345")
        #expect(requirement == #"anchor apple generic and identifier "com.withpreet.x-shredder" and certificate leaf[subject.OU] = "ABCDE12345""#)
        // Nothing that could break out of the requirement string is accepted.
        #expect(PeerRequirement.requirement(forIdentifier: "com.example\" or anchor trusted", team: "ABCDE12345") == nil)
        #expect(PeerRequirement.requirement(forIdentifier: "com.withpreet.x-shredder", team: "") == nil)
        #expect(PeerRequirement.requirement(forIdentifier: "com.withpreet.x-shredder", team: "A\" or \"") == nil)
    }

    // MARK: No override in release builds

    @Test func activePolicyMatchesTheBuildConfiguration() {
        #if DEBUG
        #expect(Policy.allowsTestDiskImages)
        #else
        #expect(!Policy.allowsTestDiskImages)
        #expect(Policy.active == Policy.standard)
        #endif
        #expect(Policy.active.allowedProtocols == ["USB", "Secure Digital"])
        #expect(Policy.active.maxSizeBytes == 2_000_000_000_000)
    }

    @Test func progressText() {
        var message = EraseProgressMessage(
            bsdName: "disk4", passIndex: 0, passCount: 2, pattern: "random", phase: "write",
            phaseBytes: 0, deviceBytes: 1, fraction: 0, bytesPerSecond: 23_400_000, secondsRemaining: 125)
        #expect(ProgressText.phase(message) == "Pass 1 of 2: Writing random data")
        #expect(ProgressText.speed(message.bytesPerSecond) == "23.4 MB/s")
        #expect(ProgressText.remaining(message.secondsRemaining) == "2 min 5 s")
        message.phase = "verify"
        #expect(ProgressText.phase(message) == "Pass 1 of 2: Verifying")
        message.passIndex = 1
        message.pattern = "zero"
        message.phase = "write"
        #expect(ProgressText.phase(message) == "Pass 2 of 2: Writing zeros")
        #expect(ProgressText.remaining(nil) == "Estimating")
        #expect(ProgressText.remaining(4000) == "1 h 6 min")
    }
}
