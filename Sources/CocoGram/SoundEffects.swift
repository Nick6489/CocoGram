import AVFoundation
import Foundation

/// Plays the app's short UI sound cues (recording lifecycle, send, receive).
///
/// These are **additive** cues layered on top of the app's VoiceOver announcements — they
/// never replace or suppress an accessibility announcement. Players are preloaded so a cue
/// fires with no decode latency at the moment of the event.
///
/// Resources resolve from the app bundle's `Resources/Sounds` (the distributed `.app`,
/// populated by `scripts/package.sh`) and fall back to `Bundle.module`'s `Sounds`
/// directory (the un-bundled `swift run` build, via the SPM `.copy("Sounds")` resource).
@MainActor
final class SoundEffects {
    static let shared = SoundEffects()

    enum Effect: String, CaseIterable {
        case startRecording = "Start Recording"
        case pauseRecording = "Pause Recording"
        case stopRecording = "Stop Recording"
        case sendMessage = "Send Message"
        case receiveMessageSameWindow = "Receive Message (Same Window)"
        case receiveMessagePush = "Receive Message (Push)"
    }

    private var players: [Effect: AVAudioPlayer] = [:]

    private init() {
        for effect in Effect.allCases {
            guard let url = Self.soundURL(named: effect.rawValue) else {
                FileHandle.standardError.write(Data(
                    "[CocoGram audio] missing sound resource: \(effect.rawValue).m4a\n".utf8
                ))
                continue
            }
            if let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                players[effect] = player
            }
        }
    }

    /// Plays a cue. If `completion` is supplied it runs after roughly the cue's duration
    /// (used to sequence around recording so a cue isn't captured into the mic); it always
    /// runs, even when the sound is unavailable, so callers never stall.
    func play(_ effect: Effect, completion: (@MainActor () -> Void)? = nil) {
        guard let player = players[effect] else {
            if let completion { Task { @MainActor in completion() } }
            return
        }
        // Route to the user's chosen sound-effects output (a device UID), or nil for the
        // system default. Set per-play so a Settings change takes effect on the next cue.
        // Assigning the device doesn't open it; only play() does, immediately below.
        player.currentDevice = AudioOutputPreference.uid(for: .soundEffects)
        player.currentTime = 0
        player.play()

        guard let completion else { return }
        let delay = max(player.duration, 0.05)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            completion()
        }
    }

    private static func soundURL(named name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "Sounds") {
            return url
        }
        return Bundle.module.url(forResource: name, withExtension: "m4a", subdirectory: "Sounds")
    }
}
