import CoreAudio
import Foundation

/// A selectable audio output device (name for display, UID for stable persistence).
struct AudioOutputDevice: Equatable, Sendable {
    let uid: String
    let name: String
}

/// Per-app output-device choices, persisted by stable device UID. Like `AudioInputPreference`
/// these are CocoGram-only — they never change the macOS system output device. Two independent
/// routes so the short UI sound effects and live call audio can target different speakers/headsets.
/// Absent = follow the system default output for that route.
enum AudioOutputPreference {
    enum Route: String {
        case soundEffects = "preferredSoundEffectsOutputDeviceUID"
        case calls = "preferredCallOutputDeviceUID"
    }

    static func uid(for route: Route) -> String? {
        UserDefaults.standard.string(forKey: route.rawValue)
    }

    static func setUID(_ uid: String?, for route: Route) {
        if let uid {
            UserDefaults.standard.set(uid, forKey: route.rawValue)
        } else {
            UserDefaults.standard.removeObject(forKey: route.rawValue)
        }
    }
}

/// Passive CoreAudio device enumeration and lookup — property reads only, never opens or wakes a
/// device (no Continuity wake, no Bluetooth HFP switch). The input picker lives in
/// `VoiceMessageRecorder`; this is the output-side counterpart plus shared lookups used by the
/// aggregate-device manager and call audio engine.
enum CoreAudioDevices {
    /// All connected output-capable devices, for the Preferences output pickers.
    static func availableOutputDevices() -> [AudioOutputDevice] {
        allDeviceIDs().compactMap { id -> AudioOutputDevice? in
            guard channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = name(of: id) else { return nil }
            return AudioOutputDevice(uid: uid, name: name)
        }
    }

    /// Resolves a CoreAudio device by its stable UID (the value persisted in preferences).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func name(of id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName) ?? stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
    }

    static func uid(of id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    /// The current system default device for the given scope (input or output), used when the
    /// user hasn't pinned a specific device.
    static func defaultDeviceID(scope: AudioObjectPropertyScope) -> AudioDeviceID? {
        let selector = scope == kAudioObjectPropertyScopeInput
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return deviceID
    }

    /// Number of channels a device exposes in the given scope (0 means it can't be used there).
    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
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
