import AVFoundation
import Foundation
import OpusShim
import opus

enum OggOpusEncoder {
    static let defaultBitrate = 160_000

    private static let sampleRate: Double = 48_000
    private static let channelCount: AVAudioChannelCount = 2
    private static let frameCapacity: AVAudioFrameCount = 5_760

    /// Encodes a recorded PCM file to Ogg Opus, resampling from whatever the input device
    /// captured (any rate, mono or multichannel) to the 48 kHz interleaved stereo that
    /// Opus requires. This is the single resample point in the send path, so recordings
    /// are always sent at a rate they play back hearably regardless of the mic hardware.
    static func encode(_ sourceURL: URL, bitrate: Int = defaultBitrate) throws -> URL {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat

        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: true
            ),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat),
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCapacity)
        else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                NSLocalizedDescriptionKey: "The recorded audio couldn't be prepared for stereo Opus encoding."
            ])
        }

        // Opus is always 48 kHz, so a non-48 kHz recording must be resampled here — but
        // only here, and only when needed (the converter is a passthrough when the source
        // is already 48 kHz). Use mastering-grade conversion for an audiophile-quality
        // result on the rates real interfaces use (44.1/88.2/96/192 kHz, etc.).
        if inputFormat.sampleRate != sampleRate {
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = .max
        }

        // The converter can emit more frames than it consumes when upsampling (e.g.
        // 44.1 kHz → 48 kHz), so the output buffer is sized to the resample ratio plus
        // slack for the resampler's internal latency.
        let resampleRatio = sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(frameCapacity) * resampleRatio).rounded(.up)) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CocoGram-\(UUID().uuidString).oga")
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        guard let comments = ope_comments_create() else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { ope_comments_destroy(comments) }

        var createError: Int32 = 0
        let encoder = outputURL.path.withCString { path in
            ope_encoder_create_file(path, comments, Int32(sampleRate), Int32(channelCount), 0, &createError)
        }
        guard let encoder else {
            throw encodingError(createError)
        }
        defer { ope_encoder_destroy(encoder) }

        try check(cocogram_ope_encoder_set_bitrate(encoder, Int32(bitrate)))

        // AVAudioConverter calls the input block synchronously on this thread, but the
        // SDK types it `@Sendable`; routing the (non-Sendable) file/buffer and the EOF
        // flag through one object keeps the capture honest instead of capturing a mutable
        // var and AVFoundation types directly.
        let pump = PCMInputPump(file: inputFile, buffer: inputBuffer)
        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: pump.next)

            switch status {
            case .error:
                throw conversionError ?? encodingError(Int32(OPE_BAD_ARG))
            case .haveData, .inputRanDry, .endOfStream:
                try writeToEncoder(encoder, buffer: outputBuffer)
            @unknown default:
                throw encodingError(Int32(OPE_BAD_ARG))
            }

            if status == .endOfStream {
                break
            }
        }

        // A genuine read fault (corrupt/truncated source) is reported by the pump as
        // end-of-stream so the converter can drain cleanly; surface it here instead of
        // silently shipping a clipped recording. (True EOF leaves readError nil.)
        if let readError = pump.readError {
            throw readError
        }

        try check(ope_encoder_drain(encoder))
        completed = true
        return outputURL
    }

    /// Feeds one interleaved-stereo float buffer to libopusenc.
    private static func writeToEncoder(_ encoder: OpaquePointer, buffer: AVAudioPCMBuffer) throws {
        let samplesPerChannel = Int32(buffer.frameLength)
        guard samplesPerChannel > 0 else { return }
        guard let samples = buffer.audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else {
            throw encodingError(Int32(OPE_BAD_ARG))
        }
        try check(ope_encoder_write_float(encoder, samples, samplesPerChannel))
    }

    private static func check(_ result: Int32) throws {
        guard result == OPE_OK else {
            throw encodingError(result)
        }
    }

    private static func encodingError(_ code: Int32) -> Error {
        CocoaError(.fileWriteUnknown, userInfo: [
            NSLocalizedDescriptionKey: "Couldn't encode the voice message as Ogg Opus (libopusenc error \(code))."
        ])
    }
}

/// Streams an input PCM file into `AVAudioConverter` one buffer at a time. The converter
/// invokes `next` synchronously while converting, so the `@unchecked Sendable` assertion
/// holds: nothing here is touched concurrently.
private final class PCMInputPump: @unchecked Sendable {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private var reachedEnd = false

    /// Set if `read` threw a real fault (not plain EOF, which doesn't throw). The encoder
    /// checks this after draining the converter and rethrows so a truncated source isn't
    /// silently sent as a complete recording.
    private(set) var readError: Error?

    init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
        self.file = file
        self.buffer = buffer
    }

    func next(_ packetCount: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        // AVAudioFile.read THROWS at end of file (it does not return a 0-frame buffer), so
        // the read is gated on there being declared frames left. That keeps a normal EOF
        // out of the catch below, leaving the catch to mean a genuine fault — a read that
        // failed while frames the header promised were still unread (corrupt/truncated
        // source). The encoder rethrows `readError` so such a clip isn't silently shipped.
        if reachedEnd || file.framePosition >= file.length {
            status.pointee = .endOfStream
            return nil
        }
        do {
            buffer.frameLength = 0
            try file.read(into: buffer)
        } catch {
            readError = error
            reachedEnd = true
            status.pointee = .endOfStream
            return nil
        }
        if buffer.frameLength == 0 {
            reachedEnd = true
            status.pointee = .endOfStream
            return nil
        }
        status.pointee = .haveData
        return buffer
    }
}
