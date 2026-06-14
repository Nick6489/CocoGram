import CoreAudio
import Foundation

/// Builds a PRIVATE CoreAudio aggregate device from a chosen input + output device so a call can
/// capture from one device and render to another WITHOUT macOS collapsing a Bluetooth headset
/// into lo-fi HFP (telephony) mode.
///
/// Ported from SyncPhone's working implementation
/// (`macos/SyncPhone/Managers/AudioDeviceManager.m:260-273, 311-389, 412-428`).
///
/// **Why this avoids the AirPods problem:** macOS flips a Bluetooth device to HFP (~8/16 kHz,
/// mono) only when ONE device must supply BOTH input and output to a duplex session. By
/// aggregating two SEPARATE sub-devices — e.g. a USB mic for input and AirPods for output — and
/// driving each through a unidirectional HAL unit (never VoiceProcessingIO, which ignores device
/// IDs and forces a duplex session), the AirPods are only ever used for output and stay in
/// high-quality A2DP. The same-device guard below stops the resolved input from accidentally
/// being the same Bluetooth device as the output.
///
/// **Headless-test safety:** `AudioHardwareCreateAggregateDevice` constructs a CoreAudio device
/// *object* (a property graph). It does NOT start an IOProc, so it never opens the underlying
/// devices for streaming and never wakes a mic or triggers HFP. Live streaming and the 48 kHz
/// nominal-rate set happen later, only during an actual call, in the media engine — never here
/// and never in tests.
final class CallAudioAggregate {
    /// The concrete (input, output) device pair a call will use, after resolution + guard.
    struct Plan: Equatable {
        let inputUID: String
        let inputName: String
        let outputUID: String
        let outputName: String
        /// True when the same-device guard swapped in a different input to avoid HFP collision.
        let substitutedInput: Bool
    }

    enum AggregateError: LocalizedError {
        case noUsableDevices
        case creationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noUsableDevices:
                return "No usable input/output device pair is available for a call."
            case .creationFailed(let status):
                return "Couldn't create the call audio device (CoreAudio error \(status))."
            }
        }
    }

    private(set) var deviceID: AudioDeviceID = 0
    static let aggregateUID = "me.giannak.nick.cocogram.callaggregate"
    var aggregateUID: String { Self.aggregateUID }

    /// Resolves the (input, output) pair for a call from the user's preferences (nil = follow the
    /// system default for that side), applying the same-device anti-HFP guard. Pure CoreAudio
    /// property reads — opens nothing.
    static func resolvePlan(inputUID: String?, outputUID: String?) -> Plan? {
        guard
            let outputID = outputUID.flatMap(CoreAudioDevices.deviceID(forUID:))
                ?? CoreAudioDevices.defaultDeviceID(scope: kAudioObjectPropertyScopeOutput),
            CoreAudioDevices.channelCount(outputID, scope: kAudioObjectPropertyScopeOutput) > 0,
            let resolvedOutputUID = CoreAudioDevices.uid(of: outputID)
        else { return nil }

        var inputID = inputUID.flatMap(CoreAudioDevices.deviceID(forUID:))
            ?? CoreAudioDevices.defaultDeviceID(scope: kAudioObjectPropertyScopeInput)
        var substituted = false

        // Same-device guard (SyncPhone AudioDeviceManager.m:260-273): if the resolved input is the
        // SAME physical device as the chosen output AND the user didn't explicitly pin an input,
        // the default input is just tracking the Bluetooth output (macOS often flips AirPods to
        // default input on connect). Pick a different input so the two never collide → no HFP.
        if inputUID == nil,
           let currentInput = inputID,
           CoreAudioDevices.uid(of: currentInput) == resolvedOutputUID,
           let alternativeUID = pickNonMatchingInput(excludingUID: resolvedOutputUID) {
            inputID = CoreAudioDevices.deviceID(forUID: alternativeUID)
            substituted = true
        }

        guard
            let resolvedInputID = inputID,
            CoreAudioDevices.channelCount(resolvedInputID, scope: kAudioObjectPropertyScopeInput) > 0,
            let resolvedInputUID = CoreAudioDevices.uid(of: resolvedInputID)
        else { return nil }

        return Plan(
            inputUID: resolvedInputUID,
            inputName: CoreAudioDevices.name(of: resolvedInputID) ?? resolvedInputUID,
            outputUID: resolvedOutputUID,
            outputName: CoreAudioDevices.name(of: outputID) ?? resolvedOutputUID,
            substitutedInput: substituted
        )
    }

    private static func pickNonMatchingInput(excludingUID: String) -> String? {
        for id in CoreAudioDevices.allDeviceIDs() {
            guard CoreAudioDevices.channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
                  let uid = CoreAudioDevices.uid(of: id), uid != excludingUID else { continue }
            return uid
        }
        return nil
    }

    /// Creates the private aggregate device for `plan`. Returns its new `AudioDeviceID`. Building
    /// it does not start IO (see the type doc), so it is safe to call (and test) without opening
    /// the underlying devices.
    @discardableResult
    func create(plan: Plan) throws -> AudioDeviceID {
        precondition(deviceID == 0, "CallAudioAggregate.create called twice without destroy")

        // Input is the master/clock sub-device (drift 0); the output is drift-compensated (drift
        // 1) so the two independent device clocks stay aligned.
        let subDevices: [[String: Any]] = [
            [kAudioSubDeviceUIDKey as String: plan.inputUID,
             kAudioSubDeviceDriftCompensationKey as String: 0],
            [kAudioSubDeviceUIDKey as String: plan.outputUID,
             kAudioSubDeviceDriftCompensationKey as String: 1],
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "CocoGram Call",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: plan.inputUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,   // hidden from other apps / the system list
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
        ]

        // Defensively remove any stale aggregate left under our UID by a prior run that didn't
        // tear down cleanly (e.g. a crash) so they never accumulate.
        Self.destroyExisting(uid: Self.aggregateUID)

        var newID = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
        guard status == noErr, newID != 0 else {
            throw AggregateError.creationFailed(status)
        }
        deviceID = newID
        return newID
    }

    /// Destroys the aggregate (idempotent), returning the CoreAudio status. Callers driving live
    /// IO must stop/release their HAL units BEFORE this (SyncPhone AudioDeviceManager.m:412-428).
    @discardableResult
    func destroy() -> OSStatus {
        guard deviceID != 0 else { return noErr }
        let victim = deviceID
        deviceID = 0
        return AudioHardwareDestroyAggregateDevice(victim)
    }

    /// Destroys any aggregate currently published under `uid` (regardless of which object created
    /// it). Used to clear a leaked aggregate before creating a fresh one.
    @discardableResult
    static func destroyExisting(uid: String) -> Bool {
        guard let id = CoreAudioDevices.deviceID(forUID: uid) else { return false }
        return AudioHardwareDestroyAggregateDevice(id) == noErr
    }

    deinit { destroy() }

    // MARK: - Inspection (used by the headless test to verify composition without opening IO)

    /// The aggregate's sub-device UIDs, in order (input first, then output).
    func subDeviceUIDs() -> [String] {
        guard deviceID != 0 else { return [] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var arrayRef: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &arrayRef) == noErr,
              let uids = arrayRef?.takeRetainedValue() as? [String] else { return [] }
        return uids
    }

    /// The UID of the master/clock sub-device (should be the input device).
    func masterSubDeviceUID() -> String? {
        guard deviceID != 0 else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyMainSubDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let resolved = value?.takeRetainedValue() else { return nil }
        return resolved as String
    }
}
