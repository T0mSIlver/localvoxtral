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

    #if canImport(CryptoKit)
    func testMatchesCryptoKitAcrossBlockBoundaries() {
        for length in 0 ... 300 {
            let data = Data((0 ..< length).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ length) })
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(PortableSHA256.hex(of: data), expected, "length \(length)")
        }
    }
    #endif
}
