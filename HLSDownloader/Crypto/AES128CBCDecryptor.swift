import Foundation

enum AES128CBCDecryptor {
    static func decrypt(_ encryptedData: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw HLSError.invalidAESKey
        }

        var decrypted = Data(count: encryptedData.count + kCCBlockSizeAES128)
        let outputCapacity = decrypted.count
        var outputLength = 0

        let status = decrypted.withUnsafeMutableBytes { outputBytes in
            encryptedData.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            encryptedData.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { throw HLSError.decryptionFailed }
        decrypted.removeSubrange(outputLength..<decrypted.count)
        return decrypted
    }

    static func initializationVector(for sequence: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        var value = sequence
        for index in stride(from: bytes.count - 1, through: bytes.count - 8, by: -1) {
            bytes[index] = UInt8(value & 0xff)
            value >>= 8
        }
        return Data(bytes)
    }
}
