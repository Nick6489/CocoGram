import CommonCrypto
import Foundation

/// Per-call media encryption for the voice stream, implementing the MTProto-2.0 scheme that
/// Telegram's libtgvoip uses for its end-to-end media layer: a per-packet `msg_key` derived from
/// the call's shared key + plaintext, `KDF2` to expand `(msg_key, key)` into an AES-256 key/IV,
/// and AES-256-**IGE** for the payload. The shared `callKey` is the DH-derived `encryption_key`
/// TDLib hands back in `callStateReady` (256 bytes).
///
/// `x` selects the direction (MTProto convention): 0 for one peer's outgoing stream, 8 for the
/// other's, so the two directions use distinct derived keys from the same shared secret.
///
/// Wire layout produced by `seal` / consumed by `open`: `msg_key (16 bytes) || AES-IGE(inner)`,
/// where `inner = UInt32-BE(payloadLength) || payload || random-pad-to-16`. `open` recomputes and
/// verifies `msg_key` (integrity) before returning the payload.
///
/// NOTE: this matches the documented MTProto-2.0 media framing. Byte-exact interop with a *live*
/// Telegram peer also depends on the negotiated tgcalls protocol layer and the outer reflector
/// framing; it is verified here by round-trip (`seal`→`open`) and is correct for our own loopback.
enum VoipCrypto {
    enum CryptoError: Error { case keyTooShort, malformedPacket, integrityCheckFailed }

    /// The shared call key must be long enough for the largest offset we read: msg_key uses
    /// `key[88+x ..< 120+x]`, so for x=8 we need ≥128 bytes. Telegram's key is 256.
    static let minimumKeyLength = 128

    /// Encrypts `payload` for direction `x`. Returns `msg_key || ciphertext`.
    static func seal(payload: [UInt8], callKey: [UInt8], x: Int) throws -> [UInt8] {
        guard callKey.count >= minimumKeyLength else { throw CryptoError.keyTooShort }
        let inner = pad(payload)
        let msgKey = messageKey(callKey: callKey, inner: inner, x: x)
        let (aesKey, aesIV) = kdf2(callKey: callKey, msgKey: msgKey, x: x)
        let ciphertext = try aesIGE(inner, key: aesKey, iv: aesIV, encrypt: true)
        return msgKey + ciphertext
    }

    /// Decrypts a `msg_key || ciphertext` packet for direction `x`, verifying integrity.
    static func open(packet: [UInt8], callKey: [UInt8], x: Int) throws -> [UInt8] {
        guard callKey.count >= minimumKeyLength else { throw CryptoError.keyTooShort }
        guard packet.count > 16, (packet.count - 16) % 16 == 0 else { throw CryptoError.malformedPacket }
        let msgKey = Array(packet[0..<16])
        let ciphertext = Array(packet[16...])
        let (aesKey, aesIV) = kdf2(callKey: callKey, msgKey: msgKey, x: x)
        let inner = try aesIGE(ciphertext, key: aesKey, iv: aesIV, encrypt: false)
        // Integrity: msg_key must equal SHA256(keyFragment || inner)[8..24]. Decrypt-then-verify is
        // safe in MTProto-2.0 because msg_key is a hash of the plaintext — any tampering changes
        // the decrypted bytes and fails this check before `inner` is used. Compared in constant
        // time so the check can't leak via a timing side channel.
        guard constantTimeEqual(messageKey(callKey: callKey, inner: inner, x: x), msgKey) else {
            throw CryptoError.integrityCheckFailed
        }
        return try unpad(inner)
    }

    // MARK: - MTProto-2.0 key derivation

    private static func messageKey(callKey: [UInt8], inner: [UInt8], x: Int) -> [UInt8] {
        var material = Array(callKey[(88 + x)..<(88 + x + 32)])
        material.append(contentsOf: inner)
        return Array(sha256(material)[8..<24])
    }

    /// MTProto-2.0 KDF2: expands (msg_key, callKey) into a 32-byte AES key and 32-byte IGE IV.
    private static func kdf2(callKey: [UInt8], msgKey: [UInt8], x: Int) -> (key: [UInt8], iv: [UInt8]) {
        let sha1 = sha256(msgKey + Array(callKey[x..<(x + 36)]))
        let sha2 = sha256(Array(callKey[(40 + x)..<(40 + x + 36)]) + msgKey)
        let key = Array(sha1[0..<8]) + Array(sha2[8..<24]) + Array(sha1[24..<32])
        let iv = Array(sha2[0..<8]) + Array(sha1[8..<24]) + Array(sha2[24..<32])
        return (key, iv)
    }

    // MARK: - Padding (length-prefixed so the exact payload is recoverable)

    private static func pad(_ payload: [UInt8]) -> [UInt8] {
        var inner = [UInt8]()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { inner.append(contentsOf: $0) }
        inner.append(contentsOf: payload)
        let remainder = inner.count % 16
        if remainder != 0 {
            inner.append(contentsOf: (0..<(16 - remainder)).map { _ in UInt8.random(in: 0...255) })
        }
        return inner
    }

    private static func unpad(_ inner: [UInt8]) throws -> [UInt8] {
        guard inner.count >= 4 else { throw CryptoError.malformedPacket }
        let length = inner.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard 4 + Int(length) <= inner.count else { throw CryptoError.malformedPacket }
        return Array(inner[4..<(4 + Int(length))])
    }

    // MARK: - Primitives (CommonCrypto)

    static func sha256(_ data: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest
    }

    /// AES-256 in IGE (Infinite Garble Extension) mode — the mode Telegram uses. Built on AES-ECB
    /// single-block ops: encrypt `c_i = E(p_i ⊕ c_{i-1}) ⊕ p_{i-1}` with `c_-1, p_-1` = the two IV
    /// halves; decrypt is the inverse. `data` must be a multiple of 16 bytes; key is 32 bytes; iv 32.
    static func aesIGE(_ data: [UInt8], key: [UInt8], iv: [UInt8], encrypt: Bool) throws -> [UInt8] {
        precondition(data.count % 16 == 0 && key.count == 32 && iv.count == 32)
        var output = [UInt8](repeating: 0, count: data.count)
        var prevCipher = Array(iv[0..<16])
        var prevPlain = Array(iv[16..<32])
        var offset = 0
        while offset < data.count {
            let block = Array(data[offset..<(offset + 16)])
            if encrypt {
                let cipher = xor(try aesECBBlock(xor(block, prevCipher), key: key, encrypt: true), prevPlain)
                for i in 0..<16 { output[offset + i] = cipher[i] }
                prevCipher = cipher
                prevPlain = block
            } else {
                let plain = xor(try aesECBBlock(xor(block, prevPlain), key: key, encrypt: false), prevCipher)
                for i in 0..<16 { output[offset + i] = plain[i] }
                prevPlain = plain
                prevCipher = block
            }
            offset += 16
        }
        return output
    }

    private static func aesECBBlock(_ block: [UInt8], key: [UInt8], encrypt: Bool) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = key.withUnsafeBytes { keyPtr in
            block.withUnsafeBytes { inPtr in
                output.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),  // no padding; IGE chaining is done above
                        keyPtr.baseAddress, key.count,
                        nil,
                        inPtr.baseAddress, 16,
                        outPtr.baseAddress, 16,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved == 16 else { throw CryptoError.malformedPacket }
        return output
    }

    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        zip(a, b).map(^)
    }

    /// Length-independent, early-exit-free byte comparison for the MAC check.
    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}
