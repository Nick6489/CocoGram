import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// A selectable microphone input device (name for display, UID for stable persistence).
struct AudioInputDevice: Equatable, Sendable {
    let uid: String
    let name: String
}

/// The user's chosen recording input, persisted by stable device UID. Per-app only — it
/// never changes the macOS system input device. Absent = follow the system default input.
enum AudioInputPreference {
    private static let key = "preferredInputDeviceUID"

    static var preferredUID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}

/// Captures microphone audio to a temporary file for voice messages.
///
/// Uses `AVCaptureSession`, which is **input-only**: it opens *only* the selected device
/// and has no output/playback path, so it cannot open or disturb any other device. Your
/// AirPods are touched only if you explicitly choose them as the input — never otherwise.
/// (`AVAudioEngine`, by contrast, drives a shared input+output I/O unit and pulls the
/// default output device into a duplex session, which is what forced AirPods into HFP.)
///
/// Audio is written at the device's **native** sample rate (whatever `AVCaptureAudioDataOutput`
/// delivers) with no resampling here; the single conversion to TDLib's 48 kHz happens once,
/// later, in `OggOpusEncoder`, and only when the native rate isn't already 48 kHz.
///
/// Sample buffers arrive on a private queue, so all mutable state is lock-guarded and the
/// type is `@unchecked Sendable`; the owning controller calls it only from the main actor.
final class VoiceMessageRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case noInputDevice
        case configurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No microphone is available to record from."
            case .configurationFailed(let detail):
                return detail
            }
        }
    }

    let url: URL

    private let session = AVCaptureSession()
    private let dataOutput = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "me.giannak.nick.cocogram.capture")
    private let lock = NSLock()
    private var outputFile: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var writtenFrames: AVAudioFrameCount = 0
    private var writeError: Error?
    private var isPaused = false
    private var runtimeErrorObserver: NSObjectProtocol?

    /// Creates a recorder writing to `url`, bound to the device chosen in Preferences (or
    /// the system default when none is chosen). Looking up / configuring the device does
    /// NOT open it — only `start()` does. Throws if no input device is available.
    init(url: URL) throws {
        self.url = url
        super.init()

        let device: AVCaptureDevice?
        if let uid = AudioInputPreference.preferredUID {
            // Resolve the chosen device by its stable UID. If it isn't available, DO NOT
            // silently fall back to the system default (which could be the AirPods) — that
            // would record from a device the user didn't pick. Surface an error instead.
            guard let chosen = AVCaptureDevice(uniqueID: uid) else {
                throw RecorderError.configurationFailed("Your selected microphone isn’t available. Choose another in Settings (⌘,).")
            }
            device = chosen
        } else {
            // No explicit choice → "System Default". (For audio capture devices,
            // AVCaptureDevice.uniqueID is the same string as the CoreAudio device UID used
            // by the picker, so a saved choice resolves here.)
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else { throw RecorderError.noInputDevice }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecorderError.configurationFailed("Couldn't open “\(device.localizedName)”: \(error.localizedDescription)")
        }

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecorderError.configurationFailed("The selected microphone can't be used for recording.")
        }
        session.addInput(input)
        dataOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(dataOutput) else {
            session.commitConfiguration()
            throw RecorderError.configurationFailed("Couldn't attach the recording output.")
        }
        session.addOutput(dataOutput)
        session.commitConfiguration()

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.setWriteErrorIfNil(error ?? RecorderError.configurationFailed("The microphone stopped during recording."))
        }
    }

    deinit {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
    }

    func start() throws {
        setPaused(false)
        // startRunning() is blocking, so run it off the main thread. It opens ONLY the
        // selected input device; being input-only, it can't disturb the output (AirPods).
        sampleQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    /// Pause keeps the session running but stops writing, so `currentTime` freezes and the
    /// device isn't reopened on resume. (Only the already-selected device is ever involved.)
    func pause() { setPaused(true) }

    func resume() throws { setPaused(false) }

    /// Stops capture and finalizes the file. Idempotent.
    func stop() {
        if session.isRunning { session.stopRunning() }
        // Drain any in-flight delegate callback so the file is complete before it's read.
        sampleQueue.sync {}
        lock.lock()
        outputFile = nil
        lock.unlock()
    }

    private func setPaused(_ value: Bool) {
        lock.lock(); isPaused = value; lock.unlock()
    }

    private func setWriteErrorIfNil(_ error: Error) {
        lock.lock(); if writeError == nil { writeError = error }; lock.unlock()
    }

    var currentTime: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(writtenFrames) / (fileFormat?.sampleRate ?? 48_000)
    }

    var captureError: Error? {
        lock.lock(); defer { lock.unlock() }
        return writeError
    }

    // MARK: - Capture callback (private sample queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard
            let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !isPaused, writeError == nil else { return }
        do {
            if outputFile == nil {
                var asbd = asbdPointer.pointee
                guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
                // The file is created from the device's actual delivered format, so it is
                // written at the native sample rate with no conversion.
                outputFile = try AVAudioFile(
                    forWriting: url,
                    settings: format.settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
                fileFormat = format
            }
            guard
                let format = fileFormat,
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            else { return }
            pcm.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
            )
            guard status == noErr else {
                writeError = RecorderError.configurationFailed("Couldn't read captured audio (\(status)).")
                return
            }
            try outputFile?.write(from: pcm)
            writtenFrames += AVAudioFrameCount(frames)
        } catch {
            writeError = error
        }
    }

    // MARK: - Device enumeration (CoreAudio; passive reads only — opens/wakes nothing)

    /// All connected input-capable devices, for the Preferences picker. Uses CoreAudio
    /// property reads only — it never opens a device or wakes Continuity.
    static func availableInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id -> AudioInputDevice? in
            guard hasInputChannels(id), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = deviceName(id) else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    static func deviceName(_ id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName) ?? stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let resolved = value?.takeRetainedValue() else { return nil }
        let string = resolved as String
        return string.isEmpty ? nil : string
    }
}
