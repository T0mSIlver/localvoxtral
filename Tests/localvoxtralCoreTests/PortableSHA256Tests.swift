#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import XCTest
@testable import localvoxtralCore

final class PortableSHA256Tests: XCTestCase {
    /// The FIPS 180-4 examples; the 56-byte one needs a second block for the
    /// length.
    func testMatchesKnownDigests() {
        let cases: [(message: String, hex: String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            ),
        ]
        for (message, hex) in cases {
            XCTAssertEqual(PortableSHA256.hex(of: Data(message.utf8)), hex, "\(message.prefix(20))…")
        }
    }

    func testAppConfigStoreHashMatchesThePortableOne() {
        for length in [0, 1, 55, 56, 63, 64, 65, 119, 120, 128, 1000] {
            let data = Data((0 ..< length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            XCTAssertEqual(AppConfigStore.sha256Hex(data), PortableSHA256.hex(of: data), "length \(length)")
        }
    }

    /// RFC 4231 cases 1, 2, 3 and 6 (a key longer than the block), plus an
    /// empty key and a key of exactly one block.
    func testHMACMatchesKnownCodes() {
        let cases: [(key: Data, message: Data, hex: String)] = [
            (
                Data(repeating: 0x0B, count: 20), Data("Hi There".utf8),
                "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
            ),
            (
                Data("Jefe".utf8), Data("what do ya want for nothing?".utf8),
                "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
            ),
            (
                Data(repeating: 0xAA, count: 20), Data(repeating: 0xDD, count: 50),
                "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
            ),
            (
                Data(repeating: 0xAA, count: 131),
                Data("Test Using Larger Than Block-Size Key - Hash Key First".utf8),
                "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
            ),
            (Data(), Data(), "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad"),
            (
                Data(repeating: 0x01, count: 64), Data("x".utf8),
                "c668fc54e1a2a267c502413f4580c5bb5d9229fef5fb9b4ff5f4ce5e76299783"
            ),
        ]
        for (index, testCase) in cases.enumerated() {
            XCTAssertEqual(
                hex(PortableSHA256.hmac(message: testCase.message, key: testCase.key)), testCase.hex,
                "portable, case \(index)"
            )
            XCTAssertEqual(
                hex(HMACSHA256.authenticationCode(for: testCase.message, key: testCase.key)), testCase.hex,
                "platform, case \(index)"
            )
        }
    }

    func testHasherMatchesTheOneShotDigestWhateverTheChunking() {
        let data = Data((0 ..< 300).map { UInt8(truncatingIfNeeded: $0 &* 97 &+ 3) })
        for chunkSize in [1, 7, 63, 64, 65, 300] {
            var hasher = SHA256Hasher()
            for start in stride(from: 0, to: data.count, by: chunkSize) {
                hasher.update(data: data[start ..< min(start + chunkSize, data.count)])
            }
            XCTAssertEqual(hasher.finalize(), PortableSHA256.digest(of: data), "chunk \(chunkSize)")
        }
        XCTAssertEqual(SHA256Hasher().finalize(), PortableSHA256.digest(of: Data()))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    #if canImport(CryptoKit)
    func testHMACMatchesCryptoKitAcrossKeyAndMessageLengths() {
        for keyLength in [0, 1, 32, 63, 64, 65, 200] {
            let key = Data((0 ..< keyLength).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ keyLength) })
            for messageLength in [0, 1, 55, 64, 119, 300] {
                let message = Data((0 ..< messageLength).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 5) })
                let expected = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
                XCTAssertEqual(
                    PortableSHA256.hmac(message: message, key: key), Array(expected),
                    "key \(keyLength), message \(messageLength)"
                )
            }
        }
    }

    func testMatchesCryptoKitAcrossBlockBoundaries() {
        for length in 0 ... 300 {
            let data = Data((0 ..< length).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ length) })
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(PortableSHA256.hex(of: data), expected, "length \(length)")
        }
    }
    #endif
}
