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
    }

    private static func log(_ s: String) { FileHandle.standardError.write(Data("[selftest] \(s)\n".utf8)) }

    /// Connects to the real, signed-in TDLib session read-only and prints a report on the
    /// two reported bugs (chats showing only the latest message; the initial-sync sound-effect
    /// flood). Runs entirely before `app.run()`, never opens a window or activates the app,
    /// and closes TDLib cleanly so the session database is flushed (never corrupted). The
    /// session is reused, never re-authenticated — see SESSION_PERSISTENCE_INVARIANT.md.
    static func runTDLibDiagnostic() {
        guard let configuration = TDLibConfiguration.resolve() else {
            log("TDLib diagnostic: no usable credentials/session; nothing to test.")
            return
        }

        let start = Date()
        let done = DispatchSemaphore(value: 0)

        Task { @MainActor in
            let client = TDLibTelegramClient(configuration: configuration)

            // Drain the update stream until the session is ready (or clearly can't proceed
            // headlessly). Returns true only on `.ready`. updateNewMessage events are recorded
            // inside the client regardless of who consumes the stream, so the Bug 2 tally is
            // unaffected by stopping here.
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
                        log("session needs interactive sign-in; cannot run headless diagnostic.")
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
            // and its lock released. (A hung wait here previously could exit holding the lock.)
            let becameReady = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await readiness.value }
                group.addTask { try? await Task.sleep(for: .seconds(30)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }

            if becameReady {
                // Probe Bug 1 as cold as possible: a brief pause lets the chat list populate,
                // but not long enough for background sync to warm per-chat history — which is
                // exactly when the user hits the "only the latest message" bug. The Bug 2
                // backfill flood streams in concurrently and is read at the end of the probe.
                try? await Task.sleep(for: .milliseconds(120))
                let report = await client.runMessageLoadingDiagnostic()
                for line in report.components(separatedBy: "\n") { log(line) }
            } else {
                log("session did not become ready within 30s; skipping probe and shutting down.")
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
        let deadline = Date().addingTimeInterval(120)
        var completed = false
        while Date() < deadline {
            if done.wait(timeout: .now()) == .success { completed = true; break }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if !completed { log("TDLib diagnostic timed out after \(Int(-start.timeIntervalSinceNow))s.") }
        log("TDLib diagnostic finished in \(Int(-start.timeIntervalSinceNow))s.")
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
