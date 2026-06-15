import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Headless diagnostics, gated behind an env var and run *before* any GUI/`app.run()`.
///
/// IMPORTANT: this NEVER opens an audio (or camera) device — it only reads CoreAudio device
/// properties (enumeration). Opening a device for capture would force Bluetooth headsets
/// into HFP lo-fi and wake Continuity mics/cameras, so capture is verified only by the user
/// in the real app, never here.
enum SelfTest {
    static func runIfRequested() {
        if ProcessInfo.processInfo.environment["COCOGRAM_SELFTEST_DEVICES"] == "1" {
            runDeviceEnumeration()
            exit(0)
        }
        if ProcessInfo.processInfo.environment["COCOGRAM_SELFTEST_TDLIB"] == "1" {
            runTDLibDiagnostic()
            exit(0)
        }
        if ProcessInfo.processInfo.environment["COCOGRAM_SELFTEST_RENDER"] == "1" {
            runRenderTest()
            exit(0)
        }
        if ProcessInfo.processInfo.environment["COCOGRAM_SELFTEST_AUDIO"] == "1" {
            runAudioDeviceTest()
            exit(0)
        }
        if ProcessInfo.processInfo.environment["COCOGRAM_SELFTEST_MEDIA"] == "1" {
            runMediaEngineLoopbackTest()
            exit(0)
        }
        if ProcessInfo.processInfo.environment["COCOGRAM_SELFTEST_CALL"] == "1" {
            MainActor.assumeIsolated { CallSelfTest.run() }  // runs on the main thread, before app.run()
            exit(0)
        }
        if ProcessInfo.processInfo.environment["COCOGRAM_SELFTEST_RECORD"] == "1" {
            runRecordingTest()
            exit(0)
        }
    }

    /// Verifies the voice-recording fix for the "OSStatus error 2003334207" report: the cryptic
    /// HAL/permission codes must classify as a microphone-access failure and surface an actionable
    /// message (never the raw code); a bogus selected device must fail gracefully; and — only when
    /// the mic is ALREADY authorized (never triggering a prompt) — a real record→encode round trip
    /// must succeed.
    static func runRecordingTest() {
        log("--- Voice recording: mic-failure classification (the 2003334207 fix) + happy path ---")

        // 1) The cryptic codes must be classified as microphone-access failures.
        let codes = [2003334207, Int(kAudioHardwareUnspecifiedError), Int(kAudioHardwareNotRunningError),
                     Int(kAudioHardwareIllegalOperationError), Int(kAudioDevicePermissionsError)]
        let classified = codes.allSatisfy {
            VoiceMessageRecorder.isMicrophoneAccessFailure(NSError(domain: NSOSStatusErrorDomain, code: $0))
        }
        let avClassified = VoiceMessageRecorder.isMicrophoneAccessFailure(NSError(domain: AVFoundationErrorDomain, code: -11800))
        log("classify HAL/permission OSStatus incl 2003334207 as mic-access: \(classified ? "PASS ✓" : "FAIL ✗"); AVFoundation error: \(avClassified ? "PASS ✓" : "FAIL ✗")")

        // 2) The user-facing message must be actionable and must NEVER contain the raw code.
        let message = VoiceMessageRecorder.RecorderError.microphoneAccessBlocked.errorDescription ?? ""
        let leaksCode = message.contains("2003334207") || message.localizedCaseInsensitiveContains("osstatus")
        let actionable = message.localizedCaseInsensitiveContains("microphone") && message.localizedCaseInsensitiveContains("settings")
        log("user message leaks raw code: \(leaksCode ? "FAIL ✗" : "no ✓"); actionable (Microphone + Settings): \(actionable ? "PASS ✓" : "FAIL ✗")")
        log("  → \"\(message)\"")

        // 3) Adversarial: a bogus selected input device must throw a friendly error (no crash/leak).
        let savedPreference = AudioInputPreference.preferredUID
        AudioInputPreference.preferredUID = "cocogram-bogus-nonexistent-device-uid"
        do {
            _ = try VoiceMessageRecorder(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("probe.caf"))
            log("bogus device: expected a thrown error, got none ✗")
        } catch {
            let text = (error as? VoiceMessageRecorder.RecorderError)?.errorDescription ?? error.localizedDescription
            log("bogus device → \"\(text)\": \(!text.contains("2003334207") ? "PASS ✓ (friendly, no code)" : "FAIL ✗")")
        }
        AudioInputPreference.preferredUID = savedPreference

        // 3b) Adversarial: a write/disk failure (mic opened fine, saving failed) must NOT be
        //     misclassified as a microphone-access block — otherwise the user is wrongly sent to
        //     the Microphone settings — and its message must carry no raw code.
        let writeErr = VoiceMessageRecorder.RecorderError.writeFailure
        let writeIsMic = VoiceMessageRecorder.isMicrophoneAccessFailure(writeErr)
        let writeMsg = writeErr.errorDescription ?? ""
        let writeLeaks = writeMsg.contains("2003334207") || writeMsg.localizedCaseInsensitiveContains("osstatus")
        let writeMisdirects = writeMsg.localizedCaseInsensitiveContains("microphone")
        log("write/disk failure classified as mic-access: \(writeIsMic ? "FAIL ✗ (would misdirect to Mic settings)" : "no ✓"); "
            + "message leaks code: \(writeLeaks ? "FAIL ✗" : "no ✓"); avoids Mic misdirection: \(writeMisdirects ? "FAIL ✗" : "PASS ✓")")
        log("  → \"\(writeMsg)\"")

        // 4) The cross-machine "running but ZERO frames" starvation (stale/mismatched TCC on a
        //    second workstation): the liveness gate MUST detect a recorder that never receives a
        //    buffer and throw a mic-access failure FAST — never return success into a dead clock.
        //    Drives the gate directly with deliveredBufferCount == 0; opens NO device.
        starvationDetected()

        // 5) Happy path — ONLY if the mic is already authorized, so we never block on a prompt.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            recordRoundTrip()
        } else {
            log("happy-path record SKIPPED: mic not pre-authorized for this binary (not triggering a prompt). "
                + "authorizationStatus=\(status.rawValue) — the classification + recovery paths above are what protect users.")
        }
        log("recording self-test complete.")
    }

    /// Records ~0.7 s from the (already-authorized) mic, then encodes to Ogg Opus and validates it —
    /// proving the end-to-end record path works and `start()` confirms the mic actually opened.
    private static func recordRoundTrip() {
        let done = DispatchSemaphore(value: 0)
        let caf = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cocogram-rectest-\(UUID().uuidString).caf")
        Task.detached {
            defer { done.signal() }
            do {
                let recorder = try VoiceMessageRecorder(url: caf)
                try await recorder.start()                       // throws an actionable error if the mic is blocked
                try? await Task.sleep(for: .milliseconds(700))
                recorder.stop()
                if let error = recorder.captureError {
                    log("  record: captureError after a confirmed start ✗ — \((error as? VoiceMessageRecorder.RecorderError)?.errorDescription ?? error.localizedDescription)")
                    return
                }
                let duration = recorder.currentTime
                log("  recorded \(String(format: "%.2f", duration))s, captureError=nil → \(duration > 0 ? "PASS ✓ (mic opened, frames captured)" : "FAIL ✗ (no frames)")")
                let ogg = try OggOpusEncoder.encode(caf)
                let bytes = (try? Data(contentsOf: ogg)) ?? Data()
                let validOgg = bytes.starts(with: [0x4F, 0x67, 0x67, 0x53])  // "OggS"
                log("  encoded \(bytes.count) bytes; valid Ogg Opus (OggS magic) = \(validOgg ? "PASS ✓" : "FAIL ✗")")
                try? FileManager.default.removeItem(at: ogg)
            } catch {
                log("  record/encode threw: \((error as? VoiceMessageRecorder.RecorderError)?.errorDescription ?? error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: caf)
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if done.wait(timeout: .now()) == .success { break }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Proves the liveness gate detects "session running but the HAL delivered ZERO buffers" (the
    /// stale/mismatched-TCC cross-machine failure, and the startRunning()-hang case) as a mic-access
    /// error within a short timeout — instead of returning success into a dead clock / dimmed Stop.
    /// Opens NO device: it builds a recorder but drives `awaitFirstBufferOrThrow` directly with
    /// deliveredBufferCount == 0 (no capture runs), then asserts it throws a mic-access error fast.
    /// On a box with no input device the recorder can't be built and the check logs SKIPPED.
    private static func starvationDetected() {
        let done = DispatchSemaphore(value: 0)
        let caf = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cocogram-starve-\(UUID().uuidString).caf")
        Task.detached {
            defer { done.signal() }
            guard let recorder = try? VoiceMessageRecorder(url: caf) else {
                log("  starvation: no input device to build a recorder — SKIPPED (gate mechanism unchanged)")
                return
            }
            let started = Date()
            do {
                // Drive the gate directly with a short timeout; do NOT call start() (that opens the
                // device). deliveredBufferCount is 0 because no capture is running → must throw.
                try await recorder.awaitFirstBufferOrThrow(timeout: 0.4)
                log("  starvation: gate returned SUCCESS with zero frames → FAIL ✗ (a dead recorder would ship)")
            } catch {
                let elapsed = Date().timeIntervalSince(started)
                let isMic = VoiceMessageRecorder.isMicrophoneAccessFailure(error)
                let msg = (error as? VoiceMessageRecorder.RecorderError)?.errorDescription ?? error.localizedDescription
                let timely = elapsed < 1.0
                log("  starvation: zero-frame gate threw in \(String(format: "%.2f", elapsed))s → "
                    + "mic-access=\(isMic ? "PASS ✓" : "FAIL ✗"), timely=\(timely ? "PASS ✓" : "FAIL ✗"), no raw code=\(msg.contains("2003334207") ? "FAIL ✗" : "PASS ✓")")
                log("  → \"\(msg)\"")
            }
            try? FileManager.default.removeItem(at: caf)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if done.wait(timeout: .now()) == .success { break }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Drives the full call media pipeline through a local UDP loopback — capture-format PCM →
    /// Opus → per-call AES-IGE encryption → reflector framing → UDP(127.0.0.1) → deframe →
    /// decrypt → Opus → PCM — and verifies the audio survives, plus crypto integrity, direction
    /// separation, and packet-loss concealment. Opens NO audio device and places NO call (the
    /// PCM is a synthesized sine, the key is a fixed stand-in, the socket talks only to itself).
    static func runMediaEngineLoopbackTest() {
        log("--- Call media engine: two-peer local loopback (no devices opened, no call placed) ---")
        do {
            let callKey = (0..<256).map { UInt8($0 & 0xFF) }          // stands in for encryption_key
            let peerTag = (0..<16).map { UInt8(0xA0 + ($0 & 0x0F)) }  // 16-byte reflector routing tag
            // Two pipelines sharing the call key, as the two ends of a real call: a caller
            // (seals x=0) and a callee (opens incoming with x=0). This is the live engine's code.
            let caller = try CallMediaPipeline(callKey: callKey, peerTag: peerTag, isOutgoing: true)
            let callee = try CallMediaPipeline(callKey: callKey, peerTag: peerTag, isOutgoing: false)

            let transport = try CallUDPTransport()
            let port = try transport.bind()
            log("UDP bound to 127.0.0.1:\(port)")

            var phase = 0.0
            func sineFrame() -> [Int16] {
                let step = 2.0 * Double.pi * 440.0 / 48_000.0
                return (0..<960).map { _ in
                    defer { phase += step }
                    return Int16(sin(phase) * 12_000)
                }
            }

            var lastIn: [Int16] = []
            var lastOut: [Int16] = []
            var pcmBytes = 0, wireBytes = 0
            // Prime ~0.5 s, then measure the last (steady-state) frame: caller → wire → callee.
            for _ in 0..<25 {
                let inFrame = sineFrame()
                let wire = try caller.packetize(frame: inFrame)
                try transport.send(wire, host: "127.0.0.1", port: port)
                guard let received = transport.receiveOnce(timeoutMilliseconds: 500) else {
                    log("LOOPBACK: no datagram received ✗"); transport.close(); return
                }
                lastIn = inFrame
                lastOut = try callee.depacketize(wire: received)
                pcmBytes = inFrame.count * 2; wireBytes = wire.count
            }

            func rms(_ f: [Int16]) -> Double {
                f.isEmpty ? 0 : sqrt(f.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(f.count))
            }
            let inRMS = rms(lastIn), outRMS = rms(lastOut)
            let ratio = inRMS > 0 ? outRMS / inRMS : 0
            let carriesAudio = outRMS > 500 && ratio > 0.3 && ratio < 3.0
            log("pipeline: PCM \(pcmBytes)B → wire \(wireBytes)B (peer_tag 16 + msg_key 16 + AES-IGE(opus))")
            log("audio survived caller→callee: inRMS=\(Int(inRMS)) outRMS=\(Int(outRMS)) ratio=\(String(format: "%.2f", ratio)) → \(carriesAudio ? "PASS ✓" : "FAIL ✗")")

            // Crypto integrity: a tampered packet must be rejected by the callee.
            var tampered = try caller.packetize(frame: sineFrame())
            tampered[tampered.count - 1] ^= 0xFF
            var integrityHeld = false
            do { _ = try callee.depacketize(wire: tampered) } catch { integrityHeld = true }
            log("crypto integrity: tampered packet rejected = \(integrityHeld ? "PASS ✓" : "FAIL ✗")")

            // Direction separation: a caller packet must NOT open as if it were the callee's own
            // outgoing (a second caller pipeline opens incoming with x=8 and should fail).
            let crossed = try CallMediaPipeline(callKey: callKey, peerTag: peerTag, isOutgoing: true)
            var directionsSeparate = false
            do { _ = try crossed.depacketize(wire: try caller.packetize(frame: sineFrame())) }
            catch { directionsSeparate = true }
            log("crypto direction: caller packet not decryptable in the caller's receive direction = \(directionsSeparate ? "PASS ✓" : "FAIL ✗")")

            // Packet-loss concealment: a lost frame yields a synthesized frame, not a crash.
            let concealed = try callee.conceal()
            log("packet-loss concealment: produced \(concealed.count)-sample frame = \(concealed.count == 960 ? "PASS ✓" : "FAIL ✗")")

            transport.close()
            log("media loopback complete.")
        } catch {
            log("media loopback FAILED: \(error)")
        }
    }

    /// Verifies the audio-output pieces with NO TDLib, NO call, and WITHOUT opening any device for
    /// IO: output-device enumeration, SFX `currentDevice` routing (configured, never played), and
    /// the CoreAudio aggregate device (created, inspected via property reads, destroyed). Creating
    /// an aggregate does not start an IOProc, so no mic is woken and no Bluetooth device flips to
    /// HFP — see CallAudioAggregate's doc and the header rule above.
    static func runAudioDeviceTest() {
        log("--- Audio output devices ---")
        let outputs = CoreAudioDevices.availableOutputDevices()
        log("\(outputs.count) output device(s):")
        for device in outputs { log("  • \(device.name)  (uid \(device.uid))") }
        log("Sound-effects output preference: \(AudioOutputPreference.uid(for: .soundEffects) ?? "(System Default)")")
        log("Call output preference: \(AudioOutputPreference.uid(for: .calls) ?? "(System Default)")")

        // SFX routing: an AVAudioPlayer accepts a device UID via `currentDevice`. Assigning it
        // configures routing WITHOUT opening the device — we never call play().
        if let url = Bundle.module.url(forResource: "Send Message", withExtension: "m4a", subdirectory: "Sounds"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            if let target = outputs.first {
                player.currentDevice = target.uid
                let roundTrips = player.currentDevice == target.uid
                player.currentDevice = nil
                let clears = player.currentDevice == nil
                log("SFX routing: currentDevice set to \(target.uid) round-trips=\(roundTrips); clear→default=\(clears) (play() never called)")
            } else {
                log("SFX routing: player built OK; no output device available to target.")
            }
        } else {
            log("SFX routing: could not load a sound resource to exercise routing.")
        }

        // Aggregate device (anti-HFP): build from the real input + call-output preferences,
        // inspect composition, destroy. Never starts IO.
        log("--- CoreAudio aggregate device (anti-HFP) ---")
        guard let plan = CallAudioAggregate.resolvePlan(
            inputUID: AudioInputPreference.preferredUID,
            outputUID: AudioOutputPreference.uid(for: .calls)
        ) else {
            log("aggregate: no usable input/output pair resolved on this machine.")
            return
        }
        log("plan: input=\"\(plan.inputName)\" + output=\"\(plan.outputName)\"  substitutedInput(anti-HFP guard)=\(plan.substitutedInput)")

        let aggregate = CallAudioAggregate()
        do {
            let id = try aggregate.create(plan: plan)
            let subs = aggregate.subDeviceUIDs()
            let master = aggregate.masterSubDeviceUID()
            log("created aggregate deviceID=\(id); sub-devices=\(subs.count) "
                + "[input present=\(subs.contains(plan.inputUID)), output present=\(subs.contains(plan.outputUID))]; "
                + "master==input=\(master == plan.inputUID)")
            let destroyStatus = aggregate.destroy()
            // Device-list removal propagates through the HAL asynchronously; give it a moment,
            // then confirm the aggregate is actually gone (no accumulation across runs).
            Thread.sleep(forTimeInterval: 0.4)
            let resolvedAfter = CoreAudioDevices.deviceID(forUID: CallAudioAggregate.aggregateUID)
            log("destroyed (status=\(destroyStatus)); deviceID now \(aggregate.deviceID); "
                + "resolvable by UID after settle=\(resolvedAfter != nil)")
        } catch {
            aggregate.destroy()
            log("aggregate creation FAILED: \(error.localizedDescription)")
        }
    }

    static func log(_ s: String) { FileHandle.standardError.write(Data("[selftest] \(s)\n".utf8)) }

    /// Connects to the real, signed-in session read-only, runs `body` once it is ready, then
    /// closes TDLib cleanly so the session database is flushed (never corrupted). Runs entirely
    /// before `app.run()`, never opens a window or activates the app, and reuses the session —
    /// never re-authenticates (see SESSION_PERSISTENCE_INVARIANT.md). `timeoutSeconds` bounds
    /// the whole run so a stalled network can never hang the test or leave the DB lock held.
    static func withReadySession(timeoutSeconds: TimeInterval, _ body: @escaping @MainActor (TDLibTelegramClient) async -> Void) {
        guard let configuration = TDLibConfiguration.resolve() else {
            log("no usable credentials/session; nothing to test.")
            return
        }

        let start = Date()
        let done = DispatchSemaphore(value: 0)

        Task { @MainActor in
            let client = TDLibTelegramClient(configuration: configuration)

            // Drain the update stream until the session is ready (or clearly can't proceed
            // headlessly). Returns true only on `.ready`.
            let readiness = Task { @MainActor () -> Bool in
                for await update in client.updates {
                    guard case .authorizationStateChanged(let state) = update else {
                        if case .startupFailed(let message) = update { log("startup failed: \(message)") ; return false }
                        continue
                    }
                    log("auth state → \(state)")
                    switch state {
                    case .ready:
                        return true
                    case .closed:
                        return false
                    case .waitingForPhoneNumber, .waitingForCode, .waitingForPassword:
                        log("session needs interactive sign-in; cannot run headless test.")
                        return false
                    default:
                        continue
                    }
                }
                return false
            }

            do { try await client.start() } catch { log("client.start() threw: \(error)") }

            // Wait for readiness, but never hang: if the network stalls, a bounded timeout must
            // still fall through to the clean shutdown below so the session database is flushed
            // and its lock released.
            let becameReady = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await readiness.value }
                group.addTask { try? await Task.sleep(for: .seconds(30)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }

            if becameReady {
                await body(client)
            } else {
                log("session did not become ready within 30s; skipping and shutting down.")
            }

            // Stop this client, then block until TDLib has flushed and closed every client,
            // mirroring applicationWillTerminate, so exiting can never corrupt the session
            // database. closeClients() waits on TDLib's background queue, so blocking the
            // main thread here is safe (the app does exactly this at termination).
            readiness.cancel()
            client.stop()
            TDLibTelegramClient.shutdownAllClients()
            done.signal()
        }

        // Pump the main run loop so the @MainActor work above can execute (the main thread
        // is otherwise blocked here, before app.run()). Bounded so a hung network can't hang
        // the test forever.
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var completed = false
        while Date() < deadline {
            if done.wait(timeout: .now()) == .success { completed = true; break }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if !completed { log("self-test timed out after \(Int(-start.timeIntervalSinceNow))s.") }
        log("self-test finished in \(Int(-start.timeIntervalSinceNow))s.")
    }

    /// Reports on the two message-loading bugs (chats showing only the latest message; the
    /// initial-sync sound-effect flood).
    static func runTDLibDiagnostic() {
        withReadySession(timeoutSeconds: 120) { client in
            // Probe Bug 1 as cold as possible: a brief pause lets the chat list populate, but
            // not long enough for background sync to warm per-chat history.
            try? await Task.sleep(for: .milliseconds(120))
            let report = await client.runMessageLoadingDiagnostic()
            for line in report.components(separatedBy: "\n") { log(line) }
        }
    }

    /// Renders real message cells offscreen against the live session to verify message spacing,
    /// real media (photo/sticker/video poster) rendering + caching, and scroll-back pagination.
    static func runRenderTest() {
        withReadySession(timeoutSeconds: 200) { client in
            let report = await RenderSelfTest.run(client: client)
            for line in report.components(separatedBy: "\n") { log(line) }
        }
    }

    /// Lists the input devices the Preferences picker will show — pure property reads.
    static func runDeviceEnumeration() {
        let preferred = AudioInputPreference.preferredUID
        log("preferred input UID = \(preferred ?? "(System Default)")")
        let devices = VoiceMessageRecorder.availableInputDevices()
        log("\(devices.count) input device(s):")
        for device in devices {
            let mark = device.uid == preferred ? "  [preferred]" : ""
            log("  • \(device.name)\(mark)  (uid \(device.uid))")
        }
    }
}
