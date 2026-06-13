import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio to a temporary file for voice messages.
///
/// Unlike `AVAudioRecorder` (which is pinned to a requested sample rate the input
/// hardware may silently ignore, yielding pitched or rejected recordings), this records
/// at the input device's *native* format — whatever rate and channel count the device
/// actually provides — so capture is always faithful and hearable. The one resample to
/// the 48 kHz stereo that Opus needs happens later, once, in `OggOpusEncoder`.
///
/// The capture tap runs on a real-time audio thread, so all mutable state is guarded by a
/// lock and the type is `@unchecked Sendable`; the owning controller touches it only from
/// the main actor.
final class VoiceMessageRecorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noInputDevice
        case engineFailed(String)
        case deviceChanged

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No microphone is available to record from."
            case .engineFailed(let detail):
                return detail
            case .deviceChanged:
                return "The microphone changed during recording, so the recording was stopped."
            }
        }
    }

    /// The native rates an input device reports, plus the rate it is currently running at.
    struct InputDeviceCapabilities {
        let deviceName: String
        let currentSampleRate: Double
        let supportedSampleRates: [Double]

        var summary: String {
            let rates = supportedSampleRates
                .map { String(format: "%.0f", $0) }
                .joined(separator: ", ")
            return "\(deviceName): currently \(String(format: "%.0f", currentSampleRate)) Hz; supports [\(rates.isEmpty ? "unknown" : rates)] Hz"
        }
    }

    let url: URL
    let recordingFormat: AVAudioFormat

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var outputFile: AVAudioFile?
    private var writtenFrames: AVAudioFrameCount = 0
    private var writeError: Error?
    private var shouldBeRunning = false
    private var configObserver: NSObjectProtocol?

    /// Creates a recorder writing to `url`. Throws before any UI commitment if there is no
    /// usable input device, so the caller can surface a clear message.
    init(url: URL) throws {
        self.url = url

        // The input node's output format on bus 0 is the device's live hardware format —
        // the authoritative rate/channel count to record at.
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        recordingFormat = hardwareFormat

        // Enumerate what the device supports and confirm our capture rate is among them.
        // This is logged (not just asserted) so sample-rate surprises are auditable.
        if let capabilities = Self.inputDeviceCapabilities() {
            let supported = capabilities.supportedSampleRates
            let isSupported = supported.isEmpty || supported.contains { abs($0 - hardwareFormat.sampleRate) < 1 }
            FileHandle.standardError.write(Data(
                "[CocoGram audio] Recording at \(String(format: "%.0f", hardwareFormat.sampleRate)) Hz, \(hardwareFormat.channelCount) ch — \(capabilities.summary). Will resample to 48000 Hz stereo for sending.\(isSupported ? "" : " WARNING: capture rate not in device's reported set.")\n".utf8
            ))
        }

        outputFile = try AVAudioFile(
            forWriting: url,
            settings: recordingFormat.settings,
            commonFormat: recordingFormat.commonFormat,
            interleaved: recordingFormat.isInterleaved
        )

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        // AVAudioEngine stops itself and drops taps when the audio route or hardware
        // format changes mid-session (default-device switch, USB unplug, the Wave Link
        // virtual device re-rating). Left unhandled this freezes capture silently, so a
        // truncated clip could ship with no warning.
        // Delivered on the main queue so the engine restart here is serialized with the
        // controller's main-actor pause()/resume()/stop() calls — AVAudioEngine is not
        // safe to mutate from two threads at once.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    /// On a configuration change the engine has already stopped. If the input still
    /// matches the format the output file was opened with, restart to keep recording;
    /// if the rate or channel count actually changed, the fixed-format file can't absorb
    /// it, so end the recording with a surfaced error rather than capturing silence.
    private func handleConfigurationChange() {
        lock.lock()
        let active = shouldBeRunning
        lock.unlock()
        guard active else { return }

        let current = engine.inputNode.outputFormat(forBus: 0)
        if current.sampleRate != recordingFormat.sampleRate || current.channelCount != recordingFormat.channelCount {
            setWriteErrorIfNil(RecorderError.deviceChanged)
            return
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                setWriteErrorIfNil(error)
            }
        }
    }

    private func setWriteErrorIfNil(_ error: Error) {
        lock.lock()
        if writeError == nil { writeError = error }
        lock.unlock()
    }

    /// Frames are appended on the audio thread; `currentTime` derives duration from the
    /// frame count so it advances only while the engine is actually running (and freezes
    /// on pause) without a separate clock.
    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let outputFile, writeError == nil else { return }
        do {
            try outputFile.write(from: buffer)
            writtenFrames += buffer.frameLength
        } catch {
            writeError = error
        }
    }

    func start() throws {
        setShouldBeRunning(true)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            setShouldBeRunning(false)
            throw RecorderError.engineFailed("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    func pause() {
        setShouldBeRunning(false)
        engine.pause()
    }

    func resume() throws {
        setShouldBeRunning(true)
        do {
            try engine.start()
        } catch {
            setShouldBeRunning(false)
            throw RecorderError.engineFailed("Couldn't resume recording: \(error.localizedDescription)")
        }
    }

    /// Stops capture and finalizes the file. Idempotent.
    func stop() {
        setShouldBeRunning(false)
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        // Release the file so it flushes to disk before the preview player reads it.
        lock.lock()
        outputFile = nil
        lock.unlock()
    }

    private func setShouldBeRunning(_ value: Bool) {
        lock.lock()
        shouldBeRunning = value
        lock.unlock()
    }

    var currentTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(writtenFrames) / recordingFormat.sampleRate
    }

    /// Any error hit while writing on the audio thread, surfaced to the main actor.
    var captureError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return writeError
    }

    // MARK: - Device enumeration

    /// Queries the default input device for the sample rates it supports and the rate it
    /// is currently running at, via CoreAudio. Returns nil if there is no input device.
    static func inputDeviceCapabilities() -> InputDeviceCapabilities? {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, 0, nil,
                &deviceIDSize, &deviceID
            ) == noErr,
            deviceID != kAudioObjectUnknown
        else {
            return nil
        }

        var currentSampleRate = Double(0)
        var rateSize = UInt32(MemoryLayout<Double>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &rateSize, &currentSampleRate)

        var supportedSampleRates: [Double] = []
        var rangesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var rangesSize = UInt32(0)
        if AudioObjectGetPropertyDataSize(deviceID, &rangesAddress, 0, nil, &rangesSize) == noErr, rangesSize > 0 {
            let count = Int(rangesSize) / MemoryLayout<AudioValueRange>.size
            var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
            if AudioObjectGetPropertyData(deviceID, &rangesAddress, 0, nil, &rangesSize, &ranges) == noErr {
                for range in ranges {
                    supportedSampleRates.append(range.mMinimum)
                    if range.mMaximum != range.mMinimum {
                        supportedSampleRates.append(range.mMaximum)
                    }
                }
            }
        }

        var deviceName = "Input device"
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr,
           let resolved = name?.takeRetainedValue() {
            deviceName = resolved as String
        }

        return InputDeviceCapabilities(
            deviceName: deviceName,
            currentSampleRate: currentSampleRate,
            supportedSampleRates: Array(Set(supportedSampleRates)).sorted()
        )
    }
}
