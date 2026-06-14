import AppKit
import Foundation
import TDLibKit

/// Headless verification of call signaling mapping and the call UI — WITHOUT placing a call or
/// sending anything. The signaling part feeds fabricated `TDLibKit.CallState` values through the
/// pure mapper; the UI part configures the real `CallViewController` offscreen and asserts the
/// controls + accessibility. No `createCall`/`acceptCall`/`discardCall` is ever called.
@MainActor
enum CallSelfTest {
    private static func log(_ s: String) { FileHandle.standardError.write(Data("[selftest] \(s)\n".utf8)) }

    static func run() {
        _ = NSApplication.shared  // offscreen view layout needs the app object; nothing is shown.
        runSignalingMapping()
        runReflectorParsing()
        runCallUIRender()
        log("call self-test complete.")
    }

    // MARK: - Signaling state mapping (pure; fabricated TDLib structs)

    private static func runSignalingMapping() {
        log("--- Call signaling: TDLib CallState → CocoCallState mapping ---")

        let incoming = TDLibTelegramClient.mapCallState(
            .callStatePending(CallStatePending(isCreated: true, isReceived: true)), isOutgoing: false)
        log("pending incoming → \(incoming) : \(incoming == .pending(isOutgoing: false, isReceived: true) ? "PASS ✓" : "FAIL ✗")")

        let exchanging = TDLibTelegramClient.mapCallState(.callStateExchangingKeys, isOutgoing: true)
        log("exchanging keys → \(exchanging) : \(exchanging == .exchangingKeys ? "PASS ✓" : "FAIL ✗")")

        let emojis = ["😀", "🎉", "🐺", "🌟"]
        let ready = TDLibTelegramClient.mapCallState(
            .callStateReady(CallStateReady(
                allowP2p: true, config: "{}", customParameters: "{}",
                emojis: emojis, encryptionKey: Data(count: 256), isGroupCallSupported: false,
                protocol: CallProtocol(libraryVersions: ["11.0.0"], maxLayer: 92, minLayer: 65, udpP2p: true, udpReflector: true),
                servers: [])),
            isOutgoing: true)
        if case .ready(let connection) = ready {
            let ok = connection.emojis == emojis && connection.encryptionKey.count == 256
            log("ready → emojis=\(connection.emojis) key=\(connection.encryptionKey.count)B : \(ok ? "PASS ✓" : "FAIL ✗")")
        } else {
            log("ready → \(ready) : FAIL ✗")
        }

        let discarded = TDLibTelegramClient.mapCallState(
            .callStateDiscarded(CallStateDiscarded(
                needDebugInformation: false, needLog: false, needRating: false,
                reason: .callDiscardReasonHungUp)),
            isOutgoing: true)
        log("discarded(hung up) → \(discarded) : \(discarded == .discarded(reason: "hung up") ? "PASS ✓" : "FAIL ✗")")
    }

    // MARK: - Reflector server mapping (from TDLib's structured `servers`)

    private static func runReflectorParsing() {
        log("--- Call reflector mapping (TDLib structured servers → engine endpoints) ---")
        let peerTag = Data((0..<16).map { UInt8($0) })
        let server = CallServer(
            id: 0, ipAddress: "149.154.175.50", ipv6Address: "", port: 595,
            type: .callServerTypeTelegramReflector(CallServerTypeTelegramReflector(isTcp: false, peerTag: peerTag))
        )
        let ready = TDLibTelegramClient.mapCallState(
            .callStateReady(CallStateReady(
                allowP2p: true, config: "{}", customParameters: "{}", emojis: ["😀", "🎉", "🐺", "🌟"],
                encryptionKey: Data(count: 256), isGroupCallSupported: false,
                protocol: CallProtocol(libraryVersions: ["11.0.0"], maxLayer: 92, minLayer: 65, udpP2p: true, udpReflector: true),
                servers: [server])),
            isOutgoing: true)
        if case .ready(let connection) = ready, let reflector = connection.reflectors.first {
            let ok = reflector.host == "149.154.175.50" && reflector.port == 595 && reflector.peerTag.count == 16 && !reflector.isTcp
            log("mapped reflector \(reflector.host):\(reflector.port) peerTag=\(reflector.peerTag.count)B udp=\(!reflector.isTcp) : \(ok ? "PASS ✓" : "FAIL ✗")")
        } else {
            log("mapped reflector: none → FAIL ✗ (a reflector server should map)")
        }
    }

    // MARK: - Call UI render

    private static func runCallUIRender() {
        log("--- Call UI render (offscreen; no sheet shown, no call placed) ---")

        func makeController() -> CallViewController {
            let controller = CallViewController(onAccept: {}, onDecline: {}, onHangUp: {}, onToggleMute: { _ in })
            _ = controller.view  // trigger loadView
            return controller
        }

        // Incoming ringing: Accept + Decline shown; End/Mute hidden.
        let incomingCall = CocoCall(id: 1, userID: 42, isOutgoing: false, isVideo: false,
                                    state: .pending(isOutgoing: false, isReceived: true), peerName: "Alex")
        let incoming = makeController()
        incoming.configure(with: incomingCall)
        let incomingOK = !incoming.acceptButton.isHidden && !incoming.declineButton.isHidden
            && incoming.hangUpButton.isHidden && incoming.peerLabel.stringValue == "Alex"
        log("incoming ringing: Accept+Decline shown, End hidden, peer=\(incoming.peerLabel.stringValue) : \(incomingOK ? "PASS ✓" : "FAIL ✗")")

        // Connected: emoji SAS shown; End + Mute shown; Accept/Decline hidden.
        let emojis = ["😀", "🎉", "🐺", "🌟"]
        let readyCall = CocoCall(id: 1, userID: 42, isOutgoing: true, isVideo: false,
                                 state: .ready(CallConnection(encryptionKey: Data(count: 256), config: "{}", customParameters: "{}", emojis: emojis, reflectors: [])),
                                 peerName: "Alex")
        let ready = makeController()
        ready.configure(with: readyCall)
        let readyOK = ready.acceptButton.isHidden && !ready.hangUpButton.isHidden && !ready.muteButton.isHidden
            && !ready.emojiLabel.isHidden && ready.emojiLabel.stringValue.contains("🐺")
        log("connected: SAS emoji shown=\(ready.emojiLabel.stringValue), End+Mute shown : \(readyOK ? "PASS ✓" : "FAIL ✗")")

        // Accessibility: every control carries a non-empty label (project invariant).
        let controls: [(String, NSView)] = [
            ("peer", ready.peerLabel), ("status", ready.statusLabel), ("accept", ready.acceptButton),
            ("decline", ready.declineButton), ("end", ready.hangUpButton), ("mute", ready.muteButton),
        ]
        let labeled = controls.allSatisfy { ($0.1.accessibilityLabel()?.isEmpty == false) }
        log("accessibility: all call controls labeled = \(labeled ? "PASS ✓" : "FAIL ✗")")

        // Offscreen render sanity: the view lays out to a non-zero size.
        let size = ready.view.fittingSize
        log("offscreen layout: \(Int(size.width))×\(Int(size.height))pt : \(size.width > 0 && size.height > 0 ? "PASS ✓" : "FAIL ✗")")
    }
}
