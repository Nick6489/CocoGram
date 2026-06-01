import Foundation

enum TelegramUpdate {
    case authorizationStateChanged(TelegramAuthorizationState)
    case chatsChanged([Conversation])
    case messagesChanged(chatID: Int64, messages: [Message])
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
    func loadContacts() async throws -> [Contact]
    func loadChannels() async throws -> [Channel]
    func loadCalls() async throws -> [CallRecord]
    func downloadVoiceMessage(fileID: Int) async throws -> URL
    func sendText(_ text: String, chatID: Int64) async throws -> Message
    func sendVoiceMessage(duration: TimeInterval, chatID: Int64) async throws -> Message
}
