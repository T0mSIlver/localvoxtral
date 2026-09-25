#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// Incremental SHA-256 for code that also builds on Linux: CryptoKit's hasher
/// on Apple platforms, and elsewhere `PortableSHA256` over the buffered input.
/// The Linux arm holds the whole message in memory, which suits the small
/// inputs its callers hash.
package struct SHA256Hasher {
    #if canImport(CryptoKit)
    private var hasher = SHA256()
    #else
    private var buffer = Data()
    #endif

    package init() {}

    package mutating func update(data: Data) {
        #if canImport(CryptoKit)
        hasher.update(data: data)
        #else
        buffer.append(data)
        #endif
    }

    package func finalize() -> [UInt8] {
        #if canImport(CryptoKit)
        Array(hasher.finalize())
        #else
        PortableSHA256.digest(of: buffer)
        #endif
    }
}

/// HMAC-SHA256: CryptoKit's on Apple platforms, `PortableSHA256.hmac`
/// elsewhere.
package enum HMACSHA256 {
    package static func authenticationCode(for message: Data, key: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        #else
        PortableSHA256.hmac(message: message, key: key)
        #endif
    }
}

extension PortableSHA256 {
    private static let blockSize = 64

    /// HMAC (RFC 2104) over `PortableSHA256`. `PortableSHA256Tests` checks it
    /// against RFC 4231 and, on a Mac, against CryptoKit.
    package static func hmac(message: Data, key: Data) -> [UInt8] {
        var block = key.count > blockSize ? digest(of: key) : [UInt8](key)
        block += [UInt8](repeating: 0, count: blockSize - block.count)
        let inner = digest(of: Data(block.map { $0 ^ 0x36 }) + message)
        return digest(of: Data(block.map { $0 ^ 0x5c } + inner))
    }
}
