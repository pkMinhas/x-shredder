import XCTest
import CryptoKit
import PDFKit
@testable import Report

final class ReportTests: XCTestCase {
    private func report(succeeded: Bool = true, verification: VerificationResult = .passed, errors: [String] = []) -> EraseReport {
        EraseReport(
            toolVersion: "1.0 (1)",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_800_003_600),
            deviceModel: "Generic STORAGE DEVICE",
            deviceSizeBytes: 31_914_983_424,
            serialNumber: "000000000821",
            passes: ["random", "zero"],
            passesVerified: succeeded ? 2 : 0,
            verification: verification,
            succeeded: succeeded,
            errors: errors
        )
    }

    // MARK: Fields and wording

    func testMethodLabelIsHonest() {
        XCTAssertEqual(report().methodLabel, "Clear via overwrite, verified")
        XCTAssertEqual(report(succeeded: false, verification: .failed).methodLabel, "Clear via overwrite, not verified")
        XCTAssertEqual(report(succeeded: false, verification: .notCompleted).methodLabel, "Clear via overwrite, not verified")
        // A run that did not succeed never gets the verified label.
        XCTAssertEqual(report(succeeded: false, verification: .passed).methodLabel, "Clear via overwrite, not verified")
        for label in [ReportWording.methodLabelVerified, ReportWording.methodLabelNotVerified] {
            XCTAssertFalse(label.localizedCaseInsensitiveContains("purge"))
        }
    }

    func testEveryReportCarriesTheLimitsStatement() {
        for candidate in [report(), report(succeeded: false, verification: .failed)] {
            XCTAssertTrue(candidate.limitsStatement.contains("remapped or spare blocks"))
            XCTAssertTrue(candidate.limitsStatement.contains("Physical destruction"))
        }
    }

    func testJSONContainsEveryRequiredField() throws {
        let signed = try ReportSigner.sign(report(errors: []), with: Curve25519.Signing.PrivateKey())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReportExporter.json(signed)) as? [String: Any])
        let fields = try XCTUnwrap(object["report"] as? [String: Any])
        for key in ["toolVersion", "startedAt", "finishedAt", "deviceModel", "deviceSizeBytes", "serialNumber",
                    "passes", "passesVerified", "verification", "succeeded", "errors", "methodLabel", "limitsStatement"] {
            XCTAssertNotNil(fields[key], key)
        }
        XCTAssertEqual(object["algorithm"] as? String, "Ed25519")
        XCTAssertNotNil(object["signature"])
        XCTAssertNotNil(object["publicKey"])
    }

    // MARK: Signing

    func testSignatureVerifiesAndSurvivesExport() throws {
        let signed = try ReportSigner.sign(report(), with: Curve25519.Signing.PrivateKey())
        XCTAssertTrue(ReportSigner.verify(signed))
        let decoded = try ReportExporter.decodeJSON(ReportExporter.json(signed))
        XCTAssertEqual(decoded, signed)
        XCTAssertTrue(ReportSigner.verify(decoded))
    }

    func testAnyChangeBreaksTheSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signed = try ReportSigner.sign(report(succeeded: false, verification: .failed, errors: ["Verification failed"]), with: key)

        var flipped = signed
        flipped.report.succeeded = true
        XCTAssertFalse(ReportSigner.verify(flipped))

        var relabelled = signed
        relabelled.report.methodLabel = ReportWording.methodLabelVerified
        XCTAssertFalse(ReportSigner.verify(relabelled))

        var otherDevice = signed
        otherDevice.report.serialNumber = "999"
        XCTAssertFalse(ReportSigner.verify(otherDevice))

        var otherKey = signed
        otherKey.publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(ReportSigner.verify(otherKey))

        var otherAlgorithm = signed
        otherAlgorithm.algorithm = "none"
        XCTAssertFalse(ReportSigner.verify(otherAlgorithm))

        var garbage = signed
        garbage.signature = "not base64"
        XCTAssertFalse(ReportSigner.verify(garbage))
    }

    func testKeyStoreReturnsAStableKey() throws {
        let store = InMemorySigningKeyStore()
        XCTAssertEqual(try store.signingKey().rawRepresentation, try store.signingKey().rawRepresentation)
    }

    // MARK: PDF

    func testPDFContainsTheReportText() throws {
        let failed = report(succeeded: false, verification: .failed, errors: ["Verification failed on pass 1: block 77 does not hold the data that was written"])
        for candidate in [report(), failed] {
            let signed = try ReportSigner.sign(candidate, with: Curve25519.Signing.PrivateKey())
            let data = ReportExporter.pdf(signed)
            XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
            let document = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertGreaterThanOrEqual(document.pageCount, 1)
            let text = (document.string ?? "").replacingOccurrences(of: "\n", with: " ")
            XCTAssertTrue(text.contains("Erase report"))
            XCTAssertTrue(text.contains(candidate.methodLabel))
            XCTAssertTrue(text.contains(candidate.succeeded ? "Erase succeeded" : "Erase failed"))
            XCTAssertTrue(text.contains("Generic STORAGE DEVICE"))
            XCTAssertTrue(text.contains("31914983424 bytes"))
            XCTAssertTrue(text.contains("000000000821"))
            XCTAssertTrue(text.contains("remapped or spare blocks"))
            XCTAssertTrue(text.contains(signed.publicKeyFingerprint))
            if !candidate.succeeded { XCTAssertTrue(text.contains("block 77")) }
        }
    }

    func testLongReportsFlowOntoMorePages() throws {
        let errors = (0..<200).map { "Error line number \($0) with enough text to take a full line of the page" }
        let signed = try ReportSigner.sign(report(succeeded: false, verification: .failed, errors: errors), with: Curve25519.Signing.PrivateKey())
        let document = try XCTUnwrap(PDFDocument(data: ReportExporter.pdf(signed)))
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertTrue((document.string ?? "").contains("Error line number 199"))
    }
}
