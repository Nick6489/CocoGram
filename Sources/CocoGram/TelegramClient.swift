import Foundation

enum TelegramUpdate {
    case authorizationStateChanged(TelegramAuthorizationState)
    case chatsChanged([Conversation])
    /// Messages newly added to a chat (not the chat's full history).
    case messagesChanged(chatID: Int64, messages: [Message])
    /// A 1:1 call's state changed (incoming, outgoing, connecting, ready, ended).
    case callChanged(CocoCall)
    /// Raw signaling data for an active call, to relay to the media engine / peer.
    case callSignalingData(callID: Int, data: Data)
    /// Startup hit a transient problem and the client is retrying. Not fatal: either
    /// the retry succeeds and the normal flow continues, or `startupFailed` follows.
    /// The message is suitable for an accessibility announcement.
    case startupStalled(message: String)
    /// The client could not finish its startup handshake (e.g. the TDLib database is
    /// locked by another running copy of the app). The session is unusable until the
    /// problem is resolved; the message is suitable for showing to the user.
    case startupFailed(message: String)
}

enum TelegramAuthorizationState: Equatable {
    case waitingForParameters
    case waitingForPhoneNumber
    case waitingForCode
    case waitingForPassword
    case ready
    case loggingOut
    case closed
    case unknown(String)
}

@MainActor
protocol TelegramClient: AnyObject {
    var updates: AsyncStream<TelegramUpdate> { get }

    func start() async throws
    func stop()
    func submitPhoneNumber(_ phoneNumber: String) async throws
    func submitAuthenticationCode(_ code: String) async throws
    func submitPassword(_ password: String) async throws
    func loadChats() async throws -> [Conversation]
    func loadMessages(chatID: Int64) async throws -> [Message]
    /// Loads the slice of history immediately older than `beforeMessageID` (the oldest
    /// message currently shown), for scroll-back. Returns oldest-first, empty at the start
    /// of available history.
    func loadOlderMessages(chatID: Int64, beforeMessageID: Int64) async throws -> [Message]
    func loadContacts() async throws -> [Contact]
    func loadChannels() async throws -> [Channel]
    func loadCalls() async throws -> [CallRecord]
    func downloadVoiceMessage(fileID: Int) async throws -> URL
    /// Downloads (and locally caches, via TDLib's file store) an arbitrary file — a photo,
    /// sticker, video poster, or the video itself — returning the local file URL once complete.
    func downloadFile(fileID: Int) async throws -> URL
    func sendText(_ text: String, chatID: Int64) async throws -> Message
    func sendVoiceMessage(fileURL: URL, duration: TimeInterval, chatID: Int64) async throws -> Message

    // Calls (1:1). Signaling only at this layer; media is handled by the call audio engine.
    /// Places an outgoing call to the private chat's user. Throws for non-private chats.
    func startCall(chatID: Int64, isVideo: Bool) async throws
    func acceptCall(callID: Int) async throws
    func discardCall(callID: Int, isVideo: Bool) async throws
    func sendCallSignalingData(callID: Int, data: Data) async throws
}
