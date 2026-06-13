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
    }

    private static func log(_ s: String) { FileHandle.standardError.write(Data("[selftest] \(s)\n".utf8)) }

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
