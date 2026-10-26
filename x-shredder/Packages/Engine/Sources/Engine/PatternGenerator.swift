import Foundation
import CommonCrypto

public enum PassPattern: String, Codable, Sendable {
    case random
    case zero
}

/// Position-dependent pseudorandom data: AES-256 in CTR mode keyed per run.
///
/// The 16-byte counter block is `pass (8 bytes, big endian)` followed by the
/// index of the 16-byte AES block within the device (8 bytes, big endian).
/// Any device block can therefore be regenerated on its own, which is what
/// verification does.
public struct PatternGenerator {
    public static let keyLength = kCCKeySizeAES256

    private let key: Data

    public init(key: Data) {
        precondition(key.count == Self.keyLength, "pattern key must be 32 bytes")
        self.key = key
    }

    public static func randomKey() throws -> Data {
        var key = Data(count: keyLength)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, keyLength, $0.baseAddress!) }
        guard status == errSecSuccess else { throw EraseError.keyGenerationFailed }
        return key
    }

    /// Fills `buffer` with the data that belongs at `startBlock` for `pass`.
    public func fill(
        _ buffer: UnsafeMutableRawBufferPointer,
        pattern: PassPattern,
        pass: Int,
        startBlock: UInt64,
        blockSize: Int
    ) throws {
        memset(buffer.baseAddress!, 0, buffer.count)
        guard pattern == .random else { return }
        precondition(blockSize % kCCBlockSizeAES128 == 0 && buffer.count % kCCBlockSizeAES128 == 0)

        var counterBlock = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let aesBlockIndex = startBlock * UInt64(blockSize / kCCBlockSizeAES128)
        withUnsafeBytes(of: UInt64(pass).bigEndian) { counterBlock.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: aesBlockIndex.bigEndian) { counterBlock.replaceSubrange(8..<16, with: $0) }

        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { keyBytes in
            CCCryptorCreateWithMode(
                CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                CCPadding(ccNoPadding), counterBlock, keyBytes.baseAddress, key.count,
                nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor
            )
        }
        guard created == kCCSuccess, let cryptor else { throw EraseError.patternFailed }
        defer { CCCryptorRelease(cryptor) }

        // Encrypting zeros in place leaves the raw keystream.
        var moved = 0
        let status = CCCryptorUpdate(cryptor, buffer.baseAddress, buffer.count, buffer.baseAddress, buffer.count, &moved)
        guard status == kCCSuccess, moved == buffer.count else { throw EraseError.patternFailed }
    }
}
