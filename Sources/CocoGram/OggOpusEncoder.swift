import AVFoundation
import Foundation
import OpusShim
import opus

enum OggOpusEncoder {
    static let defaultBitrate = 160_000

    private static let sampleRate: Double = 48_000
    private static let channelCount: AVAudioChannelCount = 2
    private static let frameCapacity: AVAudioFrameCount = 5_760

    static func encode(_ sourceURL: URL, bitrate: Int = defaultBitrate) throws -> URL {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let format = inputFile.processingFormat
        guard
            format.commonFormat == .pcmFormatFloat32,
            format.sampleRate == sampleRate,
            format.channelCount == channelCount,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
        else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                NSLocalizedDescriptionKey: "The recorded audio couldn't be prepared for stereo Opus encoding."
            ])
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
        while inputFile.framePosition < inputFile.length {
            try inputFile.read(into: buffer)
            guard buffer.frameLength > 0 else { break }

            let samplesPerChannel = Int32(buffer.frameLength)
            if format.isInterleaved {
                guard let samples = buffer.audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else {
                    throw encodingError(Int32(OPE_BAD_ARG))
                }
                try check(ope_encoder_write_float(encoder, samples, samplesPerChannel))
            } else {
                guard let channels = buffer.floatChannelData else {
                    throw encodingError(Int32(OPE_BAD_ARG))
                }
                var interleavedSamples = [Float](repeating: 0, count: Int(buffer.frameLength) * Int(channelCount))
                for frame in 0..<Int(buffer.frameLength) {
                    interleavedSamples[frame * 2] = channels[0][frame]
                    interleavedSamples[frame * 2 + 1] = channels[1][frame]
                }
                try interleavedSamples.withUnsafeBufferPointer { samples in
                    try check(ope_encoder_write_float(encoder, samples.baseAddress, samplesPerChannel))
                }
            }
        }

        try check(ope_encoder_drain(encoder))
        completed = true
        return outputURL
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
