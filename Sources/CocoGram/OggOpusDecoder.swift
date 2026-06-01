import AVFoundation
import Foundation
import opus

enum OggOpusDecoder {
    private static let sampleRate: Double = 48_000
    private static let channelCount: AVAudioChannelCount = 2
    private static let frameCapacity: AVAudioFrameCount = 5_760

    static func decodeToTemporaryPCMFile(_ sourceURL: URL) throws -> URL {
        var openError: Int32 = 0
        let opusFile = sourceURL.path.withCString { path in
            op_open_file(path, &openError)
        }
        guard let opusFile else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't open the Ogg Opus voice message (libopusfile error \(openError))."
            ])
        }
        defer { op_free(opusFile) }

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: true
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CocoGram-\(UUID().uuidString).caf")
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )

        var samples = [Float](repeating: 0, count: Int(frameCapacity) * Int(channelCount))
        while true {
            let decodedFrames = op_read_float_stereo(opusFile, &samples, Int32(samples.count))
            if decodedFrames == 0 {
                completed = true
                return outputURL
            }
            guard decodedFrames > 0 else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "Couldn't decode the Ogg Opus voice message (libopusfile error \(decodedFrames))."
                ])
            }

            buffer.frameLength = AVAudioFrameCount(decodedFrames)
            let byteCount = Int(decodedFrames) * Int(channelCount) * MemoryLayout<Float>.size
            _ = samples.withUnsafeBytes { sampleBytes in
                memcpy(buffer.audioBufferList.pointee.mBuffers.mData, sampleBytes.baseAddress, byteCount)
            }
            try outputFile.write(from: buffer)
        }
    }
}
