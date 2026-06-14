import Foundation
import opus
import OpusShim

/// Realtime Opus codec for live call audio: 48 kHz, mono, 20 ms frames (960 samples) — the format
/// Telegram voice calls use. This is the raw packet codec (libopus core), distinct from
/// `OggOpusEncoder`/`OggOpusDecoder`, which build/read an Ogg-Opus *file* for voice messages.
///
/// Configured for low-latency speech: VoIP application, in-band FEC + a packet-loss estimate so a
/// dropped frame is partly recoverable, and the decoder's PLC fills a gap when a frame never
/// arrives (pass `nil` to `decode`).
final class OpusVoiceCodec {
    static let sampleRate: Int32 = 48_000
    static let channels: Int32 = 1
    /// 20 ms at 48 kHz. Telegram's standard voice frame.
    static let frameSize: Int32 = 960
    private static let maxPacketBytes = 1500

    enum CodecError: LocalizedError {
        case encoderInit(Int32)
        case decoderInit(Int32)
        case encodeFailed(Int32)
        case decodeFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .encoderInit(let c): return "Opus encoder init failed (\(c))."
            case .decoderInit(let c): return "Opus decoder init failed (\(c))."
            case .encodeFailed(let c): return "Opus encode failed (\(c))."
            case .decodeFailed(let c): return "Opus decode failed (\(c))."
            }
        }
    }

    private let encoder: OpaquePointer
    private let decoder: OpaquePointer

    init(bitrate: Int32 = 24_000) throws {
        var error: Int32 = 0
        guard let encoder = opus_encoder_create(Self.sampleRate, Self.channels, OPUS_APPLICATION_VOIP, &error),
              error == OPUS_OK else {
            throw CodecError.encoderInit(error)
        }
        guard let decoder = opus_decoder_create(Self.sampleRate, Self.channels, &error),
              error == OPUS_OK else {
            opus_encoder_destroy(encoder)
            throw CodecError.decoderInit(error)
        }
        self.encoder = encoder
        self.decoder = decoder

        _ = cocogram_opus_encoder_set_bitrate(encoder, bitrate)
        _ = cocogram_opus_encoder_set_complexity(encoder, 10)
        _ = cocogram_opus_encoder_set_inband_fec(encoder, 1)
        _ = cocogram_opus_encoder_set_packet_loss_perc(encoder, 10)
        _ = cocogram_opus_encoder_set_signal_voice(encoder)
        _ = cocogram_opus_encoder_set_vbr(encoder, 1)
    }

    deinit {
        opus_encoder_destroy(encoder)
        opus_decoder_destroy(decoder)
    }

    /// Encodes exactly one 20 ms frame of mono Int16 PCM (960 samples) into an Opus packet.
    func encode(_ pcm: [Int16]) throws -> [UInt8] {
        precondition(pcm.count == Int(Self.frameSize), "expected a 960-sample frame")
        var packet = [UInt8](repeating: 0, count: Self.maxPacketBytes)
        let written = pcm.withUnsafeBufferPointer { source in
            packet.withUnsafeMutableBufferPointer { dest in
                opus_encode(encoder, source.baseAddress!, Self.frameSize, dest.baseAddress!, Int32(Self.maxPacketBytes))
            }
        }
        guard written > 0 else { throw CodecError.encodeFailed(written) }
        return Array(packet.prefix(Int(written)))
    }

    /// Decodes one Opus packet into a 20 ms mono Int16 frame. Pass `nil` for packet-loss
    /// concealment (the decoder synthesizes a replacement frame for a lost packet).
    func decode(_ packet: [UInt8]?) throws -> [Int16] {
        var pcm = [Int16](repeating: 0, count: Int(Self.frameSize))
        let decoded: Int32 = pcm.withUnsafeMutableBufferPointer { dest in
            if let packet {
                return packet.withUnsafeBufferPointer { source in
                    opus_decode(decoder, source.baseAddress, Int32(packet.count), dest.baseAddress!, Self.frameSize, 0)
                }
            } else {
                return opus_decode(decoder, nil, 0, dest.baseAddress!, Self.frameSize, 0)
            }
        }
        guard decoded > 0 else { throw CodecError.decodeFailed(decoded) }
        return Array(pcm.prefix(Int(decoded)))
    }
}
