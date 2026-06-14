import Foundation

/// The per-call media packetization core: turns a 20 ms PCM frame into an on-the-wire packet and
/// back. This is the exact code the live `CallMediaEngine` runs, and what the headless loopback
/// test exercises — so the test validates the real pipeline, not a parallel copy.
///
/// Wire packet = `peer_tag (16) || msg_key (16) || AES-IGE(opus)` — the libtgvoip reflector
/// framing: the unencrypted 16-byte `peer_tag` routes the packet through the reflector, and the
/// payload is the per-call MTProto-2.0-encrypted Opus frame (`VoipCrypto`).
///
/// Direction key selection (`x`) follows libtgvoip: packets FROM the caller use x=0, packets FROM
/// the callee use x=8. So a peer seals with its own direction and opens with the peer's.
///
/// Thread discipline (why `@unchecked Sendable` is safe): the Opus *encoder* is touched only via
/// `packetize` (the capture thread) and the *decoder* only via `depacketize`/`conceal` (the
/// receive thread) — never the same Opus object from two threads. The key/tag are immutable.
final class CallMediaPipeline: @unchecked Sendable {
    enum PipelineError: Error { case packetTooShort }

    private let codec: OpusVoiceCodec
    private let callKey: [UInt8]
    private let peerTag: [UInt8]
    private let outgoingX: Int
    private let incomingX: Int

    init(callKey: [UInt8], peerTag: [UInt8], isOutgoing: Bool, bitrate: Int32 = 24_000) throws {
        self.codec = try OpusVoiceCodec(bitrate: bitrate)
        self.callKey = callKey
        self.peerTag = peerTag
        self.outgoingX = isOutgoing ? 0 : 8
        self.incomingX = isOutgoing ? 8 : 0
    }

    /// Encodes + encrypts + frames one captured 20 ms mono Int16 frame for transmission.
    func packetize(frame: [Int16]) throws -> [UInt8] {
        let opus = try codec.encode(frame)
        let sealed = try VoipCrypto.seal(payload: opus, callKey: callKey, x: outgoingX)
        return peerTag + sealed
    }

    /// Strips framing + decrypts + decodes a received wire packet into a 20 ms mono Int16 frame.
    func depacketize(wire: [UInt8]) throws -> [Int16] {
        guard wire.count > 16 else { throw PipelineError.packetTooShort }
        let sealed = Array(wire[16...])  // drop the peer_tag
        let opus = try VoipCrypto.open(packet: sealed, callKey: callKey, x: incomingX)
        return try codec.decode(opus)
    }

    /// A packet-loss-concealment frame for a gap where no packet arrived.
    func conceal() throws -> [Int16] {
        try codec.decode(nil)
    }
}
