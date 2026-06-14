import AppKit

/// The in-call / incoming-call panel. Shows the peer, the call status, the 4-emoji Short
/// Authentication String (when connected, for the spoken security check), and the controls.
/// Built to be VoiceOver-first: every control carries a label/help, and status changes are
/// announced. Rendered offscreen in `CallRenderSelfTest`; controls are `let` so the test can
/// assert on them.
@MainActor
final class CallViewController: NSViewController {
    let peerLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let emojiCaptionLabel = NSTextField(labelWithString: "Verify these emoji match on both devices:")
    let emojiLabel = NSTextField(labelWithString: "")
    let acceptButton = NSButton(title: "Accept", target: nil, action: nil)
    let declineButton = NSButton(title: "Decline", target: nil, action: nil)
    let hangUpButton = NSButton(title: "End Call", target: nil, action: nil)
    let muteButton = NSButton(title: "Mute", target: nil, action: nil)

    private let onAccept: () -> Void
    private let onDecline: () -> Void
    private let onHangUp: () -> Void
    private let onToggleMute: (Bool) -> Void
    private var isMuted = false
    private var engineStatus: String?

    init(onAccept: @escaping () -> Void, onDecline: @escaping () -> Void,
         onHangUp: @escaping () -> Void, onToggleMute: @escaping (Bool) -> Void) {
        self.onAccept = onAccept
        self.onDecline = onDecline
        self.onHangUp = onHangUp
        self.onToggleMute = onToggleMute
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        peerLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        peerLabel.setAccessibilityRole(.staticText)
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityRole(.staticText)

        emojiCaptionLabel.font = .systemFont(ofSize: 12)
        emojiCaptionLabel.textColor = .secondaryLabelColor
        emojiLabel.font = .systemFont(ofSize: 30)
        emojiLabel.setAccessibilityRole(.staticText)

        acceptButton.target = self; acceptButton.action = #selector(accept)
        acceptButton.keyEquivalent = "\r"
        acceptButton.setAccessibilityLabel("Accept call")
        declineButton.target = self; declineButton.action = #selector(decline)
        declineButton.setAccessibilityLabel("Decline call")
        hangUpButton.target = self; hangUpButton.action = #selector(hangUp)
        hangUpButton.setAccessibilityLabel("End call")
        muteButton.target = self; muteButton.action = #selector(toggleMute)
        muteButton.setButtonType(.pushOnPushOff)
        muteButton.setAccessibilityLabel("Mute microphone")
        muteButton.setAccessibilityHelp("Toggles your microphone. Activate again to unmute.")

        let buttonRow = NSStackView(views: [acceptButton, declineButton, muteButton, hangUpButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        let stack = NSStackView(views: [peerLabel, statusLabel, emojiCaptionLabel, emojiLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 28, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.setFrameSize(NSSize(width: 420, height: 280))
    }

    /// Updates the panel for the latest call state, choosing which controls to show.
    func configure(with call: CocoCall) {
        peerLabel.stringValue = call.peerName
        peerLabel.setAccessibilityLabel(call.peerName)

        var status = Self.statusText(for: call)
        if let engineStatus { status += " — \(engineStatus)" }
        statusLabel.stringValue = status
        statusLabel.setAccessibilityLabel(status)

        if case .ready(let connection) = call.state, !connection.emojis.isEmpty {
            emojiLabel.stringValue = connection.emojis.joined(separator: "  ")
            emojiLabel.setAccessibilityLabel("Verification emoji: \(connection.emojis.joined(separator: ", "))")
            emojiCaptionLabel.isHidden = false
            emojiLabel.isHidden = false
        } else {
            emojiCaptionLabel.isHidden = true
            emojiLabel.isHidden = true
        }

        let isIncomingRinging: Bool
        if case .pending(let isOutgoing, _) = call.state { isIncomingRinging = !isOutgoing } else { isIncomingRinging = false }
        let isActive: Bool
        switch call.state { case .pending, .exchangingKeys, .ready: isActive = true; default: isActive = false }

        acceptButton.isHidden = !isIncomingRinging
        declineButton.isHidden = !isIncomingRinging
        hangUpButton.isHidden = isIncomingRinging || !isActive
        muteButton.isHidden = !isActive || isIncomingRinging

        announce(status)
    }

    func updateEngineStatus(_ state: CallMediaEngine.EngineState) {
        switch state {
        case .connecting: engineStatus = "connecting audio"
        case .active: engineStatus = "audio connected"
        case .failed(let message): engineStatus = "audio: \(message)"
        }
        let status = statusLabel.stringValue
        // Re-render status line with the new engine status appended is handled on next configure;
        // also reflect immediately:
        statusLabel.stringValue = engineStatus.map { "\(status.components(separatedBy: " — ").first ?? status) — \($0)" } ?? status
        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
    }

    static func statusText(for call: CocoCall) -> String {
        switch call.state {
        case .pending(let isOutgoing, _): return isOutgoing ? "Calling…" : "Incoming call"
        case .exchangingKeys: return "Connecting…"
        case .ready: return "Connected"
        case .hangingUp: return "Ending…"
        case .discarded(let reason): return "Call ended (\(reason))"
        case .failed(let message): return "Call failed: \(message)"
        }
    }

    @objc private func accept() { onAccept() }
    @objc private func decline() { onDecline() }
    @objc private func hangUp() { onHangUp() }
    @objc private func toggleMute() {
        isMuted.toggle()
        muteButton.title = isMuted ? "Unmute" : "Mute"
        muteButton.setAccessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
        onToggleMute(isMuted)
        announce(isMuted ? "Microphone muted" : "Microphone unmuted")
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: statusLabel, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Owns the live call: presents the panel as a sheet on the main window, drives it from the
/// update stream, and starts/stops the media engine as the call connects/ends. The app's media
/// device preferences (mic input + call output) feed the engine's aggregate device.
@MainActor
final class CallController {
    private let telegramClient: TelegramClient
    private weak var parentWindow: NSWindow?

    private var currentCall: CocoCall?
    private var sheetWindow: NSWindow?
    private var callViewController: CallViewController?
    private var mediaEngine: CallMediaEngine?
    private var dismissTask: Task<Void, Never>?

    init(telegramClient: TelegramClient) {
        self.telegramClient = telegramClient
    }

    func setParentWindow(_ window: NSWindow?) {
        parentWindow = window
    }

    /// Routes a call state change from the update stream.
    func handle(_ call: CocoCall) {
        currentCall = call
        switch call.state {
        case .discarded, .failed, .hangingUp:
            callViewController?.configure(with: call)
            stopEngine()
            scheduleDismiss()
        default:
            dismissTask?.cancel()  // fresh call activity supersedes any pending dismiss
            dismissTask = nil
            presentIfNeeded()
            callViewController?.configure(with: call)
            if case .ready(let connection) = call.state {
                startEngine(connection: connection, isOutgoing: call.isOutgoing)
            }
        }
    }

    func handleSignalingData(_ data: Data, callID: Int) {
        // Inbound peer signaling for the WebRTC path would be fed to the media engine here. The
        // reflector path used by the current engine doesn't require it; retained as the seam.
    }

    private func presentIfNeeded() {
        guard sheetWindow == nil, let parentWindow else { return }
        let controller = CallViewController(
            onAccept: { [weak self] in self?.acceptCall() },
            onDecline: { [weak self] in self?.endCall() },
            onHangUp: { [weak self] in self?.endCall() },
            onToggleMute: { [weak self] muted in self?.mediaEngine?.setMuted(muted) }
        )
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.title = "Call"
        callViewController = controller
        sheetWindow = window
        parentWindow.beginSheet(window) { _ in }
    }

    private func startEngine(connection: CallConnection, isOutgoing: Bool) {
        guard mediaEngine == nil else { return }
        let engine = CallMediaEngine()
        engine.onStateChange = { [weak self] state in self?.callViewController?.updateEngineStatus(state) }
        mediaEngine = engine
        engine.start(
            connection: connection,
            inputUID: AudioInputPreference.preferredUID,
            outputUID: AudioOutputPreference.uid(for: .calls),
            isOutgoing: isOutgoing
        )
    }

    private func stopEngine() {
        mediaEngine?.stop()
        mediaEngine = nil
    }

    private func acceptCall() {
        guard let id = currentCall?.id else { return }
        Task { try? await telegramClient.acceptCall(callID: id) }
    }

    private func endCall() {
        guard let call = currentCall else { dismiss(); return }
        Task { try? await telegramClient.discardCall(callID: call.id, isVideo: call.isVideo) }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        stopEngine()
        if let sheetWindow, let parentWindow {
            parentWindow.endSheet(sheetWindow)
        }
        sheetWindow = nil
        callViewController = nil
        currentCall = nil
    }
}
