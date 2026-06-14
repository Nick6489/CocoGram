@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// The live call audio engine: it owns the CoreAudio aggregate device (so a separate mic + AirPods
/// pair never degrades to lo-fi HFP), captures mic PCM and renders peer PCM through that aggregate
/// via `AVAudioEngine`, and runs each 20 ms frame through the verified `CallMediaPipeline`
/// (Opus + per-call AES-IGE) over UDP to the Telegram reflector.
///
/// The codec / crypto / framing / transport core is verified end-to-end by the headless loopback
/// test (`CallMediaPipeline` + `CallUDPTransport`). The device-opening audio I/O and the live
/// reflector handshake below run only during a real call (they open the mic, which the headless
/// tests deliberately never do) and are the part a live call validates.
///
/// `AVAudioEngine` is used in plain HAL mode (NOT voice-processing IO, which ignores device IDs
/// and forces a duplex session that flips Bluetooth to HFP — the SyncPhone lesson). Pointed at the
/// aggregate, the AirPods sub-device is output-only and stays in A2DP.
@MainActor
final class CallMediaEngine {
    enum EngineState: Equatable {
        case connecting
        case active
        case failed(String)
    }

    private let aggregate = CallAudioAggregate()
    private var transport: CallUDPTransport?
    private var pipeline: CallMediaPipeline?
    private let engine = AVAudioEngine()
    private let jitter = JitterBuffer()
    private var started = false

    private(set) var state: EngineState = .connecting
    var onStateChange: ((EngineState) -> Void)?

    /// 48 kHz mono — the call audio format.
    private let frameFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!

    /// Resolves the device pair, builds the aggregate, opens the transport, and starts capture +
    /// playback. `inputUID`/`outputUID` are the user's preferences (nil = system default).
    func start(connection: CallConnection, inputUID: String?, outputUID: String?, isOutgoing: Bool) {
        guard !started else { return }
        started = true
        setState(.connecting)

        guard let plan = CallAudioAggregate.resolvePlan(inputUID: inputUID, outputUID: outputUID) else {
            return fail("No usable microphone/speaker pair for the call.")
        }
        do {
            try aggregate.create(plan: plan)
        } catch {
            return fail("Couldn't set up the call audio device: \(error.localizedDescription)")
        }

        // Prefer a UDP reflector; the engine speaks the reflector protocol, not WebRTC/TCP.
        guard let reflector = connection.reflectors.first(where: { !$0.isTcp }) ?? connection.reflectors.first else {
            // Signaling succeeded and the aggregate is ready, but there's no reflector relay we can
            // reach (e.g. a WebRTC-only call) — surface that rather than present silent dead air.
            return fail("This call uses a connection type CocoGram's media engine can't reach yet.")
        }

        let key = [UInt8](connection.encryptionKey)
        do {
            let transport = try CallUDPTransport()
            try transport.bind()
            self.transport = transport
            self.pipeline = try CallMediaPipeline(callKey: key, peerTag: [UInt8](reflector.peerTag), isOutgoing: isOutgoing)

            // The receive loop runs on a background thread and must not touch main-actor state:
            // it decrypts+decodes on that thread (the decoder is used only here) and hands PCM to
            // the lock-guarded jitter buffer, which the audio render thread drains.
            let receivePipeline = self.pipeline
            let receiveJitter = self.jitter
            transport.startReceiving { datagram in
                guard let frame = try? receivePipeline?.depacketize(wire: datagram) else { return }
                receiveJitter.enqueue(frame)
            }
            try configureAudioGraph(reflector: reflector)
            setState(.active)
        } catch {
            fail("Couldn't start call audio: \(error.localizedDescription)")
        }
    }

    func setMuted(_ muted: Bool) {
        engine.inputNode.volume = muted ? 0 : 1
    }

    func stop() {
        guard started else { return }
        started = false
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        transport?.close()
        transport = nil
        pipeline = nil
        aggregate.destroy()
    }

    // MARK: - Audio graph

    enum EngineError: LocalizedError {
        case deviceTargetingFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .deviceTargetingFailed(let s): return "Couldn't route the call to the chosen devices (CoreAudio error \(s))."
            }
        }
    }

    private func configureAudioGraph(reflector: CallReflectorServer) throws {
        // Point the engine's shared HAL I/O unit at the aggregate device (both capture + render).
        // The status MUST be checked: on failure the HAL silently falls back to the system-default
        // device, which would defeat the whole anti-HFP aggregate. Fail loudly instead.
        guard let unit = engine.outputNode.audioUnit else {
            throw EngineError.deviceTargetingFailed(-1)
        }
        var deviceID = aggregate.deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw EngineError.deviceTargetingFailed(status) }

        // Playback: a source node (audio render thread) drains decoded peer frames from the jitter
        // buffer, or renders silence on underrun. It never decodes (the decoder lives on the
        // receive thread), so no Opus object is touched from two threads.
        let renderJitter = self.jitter
        let sourceNode = AVAudioSourceNode(format: frameFormat) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let samples = renderJitter.nextFrame()
            if let out = buffers.first?.mData?.assumingMemoryBound(to: Int16.self) {
                for i in 0..<Int(frameCount) { out[i] = i < samples.count ? samples[i] : 0 }
            }
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: frameFormat)

        // Capture: tap the mic (capture thread), reframe to 20 ms mono Int16, packetize (encoder
        // lives only here), and send to the reflector.
        let capturePipeline = self.pipeline
        let captureTransport = self.transport
        let format = frameFormat
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        // The converter is created and used entirely on the capture (tap) thread — AVAudioConverter
        // is not thread-safe, so it must never be touched from another thread.
        let converterBox = ConverterBox()
        let framer = FrameAccumulator(frameSize: Int(OpusVoiceCodec.frameSize))
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let converter = converterBox.converter(from: buffer.format, to: format),
                  let mono = Self.convert(buffer, using: converter, to: format) else { return }
            for frame in framer.push(mono) {
                if let wire = try? capturePipeline?.packetize(frame: frame) {
                    try? captureTransport?.send(wire, host: reflector.host, port: reflector.port)
                }
            }
        }

        engine.prepare()
        try engine.start()
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> [Int16]? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let once = SuppliedOnce()
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if once.done { status.pointee = .noDataNow; return nil }
            once.done = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    private func setState(_ newState: EngineState) {
        state = newState
        onStateChange?(newState)
    }

    private func fail(_ message: String) {
        setState(.failed(message))
        stop()
    }
}

/// One-shot flag for the AVAudioConverter input block (called synchronously on one thread).
private final class SuppliedOnce: @unchecked Sendable { var done = false }

/// Lazily builds and owns the capture-thread `AVAudioConverter` (input device format → 48 kHz mono
/// Int16). Created and used only on the capture/tap thread, so `AVAudioConverter`'s non-thread-safe
/// internal resampler state is never shared across threads.
private final class ConverterBox: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func converter(from input: AVAudioFormat, to output: AVAudioFormat) -> AVAudioConverter? {
        if converter == nil || sourceFormat != input {
            converter = AVAudioConverter(from: input, to: output)
            sourceFormat = input
        }
        return converter
    }
}

/// Accumulates variable-length PCM into fixed 20 ms frames for the codec. A reference type so it
/// can be mutated in place from the capture-thread tap block. Touched only on that one thread.
private final class FrameAccumulator: @unchecked Sendable {
    private let frameSize: Int
    private var pending: [Int16] = []

    init(frameSize: Int) { self.frameSize = frameSize }

    func push(_ samples: [Int16]) -> [[Int16]] {
        pending.append(contentsOf: samples)
        var frames: [[Int16]] = []
        while pending.count >= frameSize {
            frames.append(Array(pending.prefix(frameSize)))
            pending.removeFirst(frameSize)
        }
        return frames
    }
}

/// A small jitter buffer: holds a few frames so network reordering/late arrival doesn't underrun
/// the render callback, and substitutes packet-loss concealment when empty.
final class JitterBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[Int16]] = []
    private let targetDepth = 6   // ~120 ms prefetch
    private var priming = true

    func enqueue(_ frame: [Int16]) {
        lock.lock(); defer { lock.unlock() }
        frames.append(frame)
        if frames.count >= targetDepth { priming = false }
        if frames.count > 25 { frames.removeFirst(frames.count - 25) }  // cap ~500 ms
    }

    /// The next frame to render: a buffered frame, or silence while priming/underrunning. (PLC is
    /// not done here — the Opus decoder lives only on the receive thread; rendering silence on an
    /// underrun keeps each Opus object single-threaded.)
    func nextFrame() -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        if priming || frames.isEmpty {
            return [Int16](repeating: 0, count: Int(OpusVoiceCodec.frameSize))
        }
        return frames.removeFirst()
    }
}
