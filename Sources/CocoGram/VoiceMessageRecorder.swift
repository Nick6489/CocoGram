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
        case selectedDeviceUnavailable
        /// The microphone exists but the OS won't let us open it — a permission/TCC or HAL block.
        /// This is the case behind the cryptic "OSStatus error 2003334207" reports.
        case microphoneAccessBlocked
        /// The mic opened fine but writing/decoding the captured audio failed (disk full, file
        /// permissions, a bad sample buffer). NOT a microphone-access issue — so it must never be
        /// routed to the Microphone settings recovery, and it never carries a raw OSStatus.
        case writeFailure
        case configurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No microphone is available to record from. Connect or enable a microphone, then try again."
            case .selectedDeviceUnavailable:
                return "Your selected microphone isn’t available. Choose another in Settings (⌘,)."
            case .microphoneAccessBlocked:
                return "CocoGram couldn’t use the microphone. Open System Settings ▸ Privacy & Security ▸ "
                    + "Microphone and make sure CocoGram is turned on. If it’s already on, switch it off and "
                    + "back on, then try recording again."
            case .writeFailure:
                return "The recording couldn’t be saved. Make sure there’s free disk space, then try again."
            case .configurationFailed(let detail):
                return detail
            }
        }

        /// True when the right recovery is the System Settings ▸ Privacy ▸ Microphone pane.
        var isMicrophoneAccessIssue: Bool {
            if case .microphoneAccessBlocked = self { return true }
            return false
        }
    }

    /// Classifies any error from the capture pipeline as a microphone-access failure. The OS
    /// reports a blocked/un-startable input HAL as a generic, cryptic OSStatus (e.g. 2003334207 =
    /// 'wht?'), or as an AVFoundation capture error — all of which mean, for a recorder, "we
    /// couldn't get the microphone." Used so the UI shows an actionable message, never the raw code.
    static func isMicrophoneAccessFailure(_ error: Error) -> Bool {
        if let recorderError = error as? RecorderError { return recorderError.isMicrophoneAccessIssue }
        let nsError = error as NSError
        let blockedCodes: Set<Int> = [
            2003334207,                               // 'wht?' generic HAL/stream "unspecified"
            Int(kAudioHardwareUnspecifiedError),      // 'what'
            Int(kAudioHardwareNotRunningError),       // 'stop'
            Int(kAudioHardwareIllegalOperationError), // 'nope'
            Int(kAudioHardwareBadDeviceError),        // '!dev'
            Int(kAudioDevicePermissionsError),        // '!hog'
        ]
        if blockedCodes.contains(nsError.code) { return true }
        // An AVFoundation-domain error here can only have come from the capture pipeline
        // (AVCaptureDeviceInput construction or AVCaptureSession.runtimeErrorNotification) — i.e.
        // the input device itself failing, which for a recorder means "we couldn't get the mic."
        // File/data write failures are wrapped as RecorderError.writeFailure and caught above by
        // the `as? RecorderError` branch, so they never reach (and are never misclassified by) this.
        if nsError.domain == AVFoundationErrorDomain { return true }
        return false
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
                throw RecorderError.selectedDeviceUnavailable
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
            // Never surface the raw OSStatus; map a blocked mic to the actionable message.
            if Self.isMicrophoneAccessFailure(error) { throw RecorderError.microphoneAccessBlocked }
            throw RecorderError.configurationFailed("Couldn’t open “\(device.localizedName)”. Choose another microphone in Settings (⌘,).")
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

    /// Starts capture and CONFIRMS the input actually came up before returning. `startRunning()`
    /// never throws — a microphone blocked by TCC/permission or an un-startable HAL surfaces only
    /// as `isRunning == false` and/or an async runtime-error notification (the cryptic
    /// "OSStatus 2003334207" path). Confirming here lets the caller present an actionable error
    /// immediately instead of leaking a raw OSStatus mid-recording.
    func start() async throws {
        setPaused(false)
        clearWriteError()
        // startRunning() is blocking, so run it off the main thread. It opens ONLY the selected
        // input device; being input-only, it can't disturb the output (AirPods).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sampleQueue.async { [weak self] in
                if let self, !self.session.isRunning { self.session.startRunning() }
                continuation.resume()
            }
        }
        // Give a runtime error (e.g. a TCC/HAL denial) a brief moment to post, then verify the
        // session is genuinely running. Any failure here means we couldn't get the microphone.
        try? await Task.sleep(for: .milliseconds(250))
        // Read the captured error ONCE into a local. Don't re-clear it here: line 174 already gave
        // this start() a clean slate, and a second clear would race the runtime-error observer
        // (which fires on a background thread) — wiping a failure that posts in the gap, so start()
        // would falsely report success and recording would silently produce nothing.
        if let error = captureError {
            throw Self.isMicrophoneAccessFailure(error) ? RecorderError.microphoneAccessBlocked
                                                        : RecorderError.configurationFailed("Recording couldn’t start. Please try again.")
        }
        guard session.isRunning else { throw RecorderError.microphoneAccessBlocked }
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

    private func clearWriteError() {
        lock.lock(); writeError = nil; lock.unlock()
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
                // Never bake the raw OSStatus into a user-facing string — surface a clean,
                // actionable write failure instead (see RecorderError.writeFailure).
                writeError = RecorderError.writeFailure
                return
            }
            try outputFile?.write(from: pcm)
            writtenFrames += AVAudioFrameCount(frames)
        } catch {
            // AVAudioFile create/write failures are disk/file problems, not a mic block. Wrap them
            // as a clean writeFailure so the UI never shows a raw error and never misdirects the
            // user to the Microphone settings.
            writeError = RecorderError.writeFailure
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
