import Foundation
import CoreGraphics
import CoreText

public enum ReportExporter {
    // MARK: JSON

    public static func json(_ signed: SignedReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(signed)
    }

    public static func decodeJSON(_ data: Data) throws -> SignedReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SignedReport.self, from: data)
    }

    // MARK: Text

    /// Label and value rows, shared by the PDF and anything that shows the
    /// report as text.
    public static func rows(_ signed: SignedReport) -> [(label: String, value: String)] {
        let report = signed.report
        let dates = ISO8601DateFormatter()
        var rows: [(String, String)] = [
            ("Result", report.succeeded ? "Erase succeeded" : "Erase failed"),
            ("Method", report.methodLabel),
            ("Verification", verificationText(report.verification)),
            ("Device model", report.deviceModel),
            ("Device size", "\(report.deviceSizeBytes) bytes"),
            ("Serial number", report.serialNumber ?? "Not available"),
            ("Passes", report.passes.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: ", ")),
            ("Passes verified", "\(report.passesVerified) of \(report.passes.count)"),
            ("Started", dates.string(from: report.startedAt)),
            ("Finished", dates.string(from: report.finishedAt)),
            ("Tool version", report.toolVersion),
        ]
        rows.append(("Errors", report.errors.isEmpty ? "None" : report.errors.joined(separator: "\n")))
        rows.append(("Limits", report.limitsStatement))
        rows.append(("Signature", "\(signed.algorithm) \(signed.signature)"))
        rows.append(("Public key", signed.publicKey))
        rows.append(("Key fingerprint", signed.publicKeyFingerprint))
        return rows
    }

    static func verificationText(_ result: VerificationResult) -> String {
        switch result {
        case .passed: return "Passed (full read-back of every pass)"
        case .failed: return "Failed"
        case .notCompleted: return "Not completed"
        }
    }

    // MARK: PDF

    public static func pdf(_ signed: SignedReport) -> Data {
        let text = NSMutableAttributedString()
        let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil)
        let labelFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 10, nil)
        let bodyFont = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        let monoFont = CTFontCreateWithName("Menlo" as CFString, 8, nil)

        func append(_ string: String, _ font: CTFont) {
            text.append(NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
        }

        append("Erase report\n\n", titleFont)
        for (label, value) in rows(signed) {
            append("\(label)\n", labelFont)
            let isKeyMaterial = label == "Signature" || label == "Public key" || label == "Key fingerprint"
            append("\(value)\n\n", isKeyMaterial ? monoFont : bodyFont)
        }

        let output = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return Data() }

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let textRect = mediaBox.insetBy(dx: 56, dy: 56)
        var location = 0
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            location += visible.length
        } while location < text.length
        context.closePDF()
        return output as Data
    }
}
