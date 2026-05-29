import Foundation
@preconcurrency import TDLibKit

extension TDLibKit.Chat: @retroactive @unchecked Sendable {}
extension TDLibKit.Chats: @retroactive @unchecked Sendable {}
extension TDLibKit.Message: @retroactive @unchecked Sendable {}
extension TDLibKit.Messages: @retroactive @unchecked Sendable {}
extension TDLibKit.Ok: @retroactive @unchecked Sendable {}
extension TDLibKit.User: @retroactive @unchecked Sendable {}

struct TDLibConfiguration {
    let apiID: Int
    let apiHash: String
    let databaseDirectory: String
    let filesDirectory: String
    let useTestDataCenter: Bool

    /// Resolves credentials from, in order of precedence (highest first): environment
    /// variables, `.cocogram.local` in the working directory (developer workflows), then
    /// credentials saved in Application Support by the in-app setup screen (end users).
    /// Returns nil when no API credentials are available from any source.
    static func resolve() -> TDLibConfiguration? {
        var values = savedConfiguration()
        values.merge(localConfiguration()) { _, new in new }
        values.merge(ProcessInfo.processInfo.environment) { _, new in new }

        guard
            let apiIDString = values["COCOGRAM_API_ID"],
            let apiID = Int(apiIDString),
            let apiHash = values["COCOGRAM_API_HASH"],
            !apiHash.isEmpty
        else {
            return nil
        }

        let baseDirectory = appSupportDirectory().path
        return TDLibConfiguration(
            apiID: apiID,
            apiHash: apiHash,
            databaseDirectory: values["COCOGRAM_TDLIB_DATABASE"] ?? "\(baseDirectory)/tdlib/database",
            filesDirectory: values["COCOGRAM_TDLIB_FILES"] ?? "\(baseDirectory)/tdlib/files",
            useTestDataCenter: values["COCOGRAM_TDLIB_TEST_DC"] == "1"
        )
    }

    /// True when usable credentials already exist anywhere — used to decide whether the
    /// first-run setup screen needs to be shown.
    static var hasUsableCredentials: Bool {
        resolve() != nil
    }

    /// The app's per-user data directory: ~/Library/Application Support/CocoGram.
    static func appSupportDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("CocoGram", isDirectory: true)
    }

    private static var savedCredentialsURL: URL {
        appSupportDirectory().appendingPathComponent("credentials.conf")
    }

    /// Persists credentials entered through the in-app setup screen so the next launch
    /// finds them automatically. Written with 0600 permissions since the file holds the
    /// app's API hash; the user's actual Telegram login lives in TDLib's encrypted database.
    static func saveCredentials(apiID: Int, apiHash: String, useTestDataCenter: Bool) throws {
        let directory = appSupportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var lines = [
            "# Written by CocoGram. Holds your my.telegram.org API credentials.",
            "COCOGRAM_API_ID=\(apiID)",
            "COCOGRAM_API_HASH=\(apiHash)"
        ]
        if useTestDataCenter {
            lines.append("COCOGRAM_TDLIB_TEST_DC=1")
        }

        let url = savedCredentialsURL
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func savedConfiguration() -> [String: String] {
        parseKeyValueFile(at: savedCredentialsURL)
    }

    private static func localConfiguration() -> [String: String] {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cocogram.local")
        return parseKeyValueFile(at: url)
    }

    /// Parses a `KEY=VALUE` file (blank lines and `#` comments ignored). Shared by the
    /// `.cocogram.local` developer file and the saved-credentials file.
    private static func parseKeyValueFile(at url: URL) -> [String: String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        var values: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
}

enum TDLibTelegramClientError: LocalizedError {
    case clientNotStarted
    case unsupportedVoiceMessagePlaceholder

    var errorDescription: String? {
        switch self {
        case .clientNotStarted:
            return "TDLib client has not been started."
        case .unsupportedVoiceMessagePlaceholder:
            return "Voice-message upload needs a recorded audio file before it can be sent through TDLib."
        }
    }
}

final class TDLibTelegramClient: TelegramClient {
    let updates: AsyncStream<TelegramUpdate>

    private let continuation: AsyncStream<TelegramUpdate>.Continuation
    private let configuration: TDLibConfiguration
    private let manager = TDLibClientManager()
    private lazy var updateBridge = TDLibUpdateBridge(owner: self)
    private var client: TDLibClient?
    private var chatCache: [Int64: TDLibKit.Chat] = [:]
    private var userCache: [Int64: TDLibKit.User] = [:]
    private var chatLastMessageCache: [Int64: TDLibKit.Message?] = [:]

    init(configuration: TDLibConfiguration) {
        self.configuration = configuration
        let stream = AsyncStream<TelegramUpdate>.makeStream()
        updates = stream.stream
        continuation = stream.continuation
    }

    func start() async throws {
        try prepareStorage()
        if client == nil {
            let updateBridge = updateBridge
            let newClient = manager.createClient(updateHandler: updateBridge.handle(data:client:))
            configureTDLibLogging(for: newClient)
            client = newClient
        }
    }

    func submitPhoneNumber(_ phoneNumber: String) async throws {
        let _: Ok = try await runTDLibRequest { completion in
            try tdClient.setAuthenticationPhoneNumber(phoneNumber: phoneNumber, settings: nil, completion: completion)
        }
    }

    func submitAuthenticationCode(_ code: String) async throws {
        let _: Ok = try await runTDLibRequest { completion in
            try tdClient.checkAuthenticationCode(code: code, completion: completion)
        }
    }

    func submitPassword(_ password: String) async throws {
        let _: Ok = try await runTDLibRequest { completion in
            try tdClient.checkAuthenticationPassword(password: password, completion: completion)
        }
    }

    func loadChats() async throws -> [Conversation] {
        _ = try? await runTDLibRequest { completion in
            try tdClient.loadChats(chatList: .chatListMain, limit: 50, completion: completion)
        } as Ok
        return try await fetchChats()
    }

    private func fetchChats() async throws -> [Conversation] {
        let chats: Chats = try await runTDLibRequest { completion in
            try tdClient.getChats(chatList: .chatListMain, limit: 50, completion: completion)
        }
        var conversations: [Conversation] = []

        for chatID in chats.chatIds {
            let chat = try await loadChat(id: chatID)
            conversations.append(mapConversation(chat))
        }

        return conversations
    }

    func loadMessages(chatID: Int64) async throws -> [Message] {
        _ = try? await runTDLibRequest { completion in
            try tdClient.openChat(chatId: chatID, completion: completion)
        } as Ok

        let chat = try? await fetchChat(id: chatID)
        let history = try await loadLatestMessages(chatID: chatID)

        var tdMessages = history.messages ?? []
        if tdMessages.isEmpty, let lastMessage = chat?.lastMessage {
            tdMessages = [lastMessage]
        }
        if let lastMessage = chat?.lastMessage, !tdMessages.contains(where: { $0.id == lastMessage.id }) {
            tdMessages.insert(lastMessage, at: 0)
        }

        var mappedMessages: [Message] = []
        for tdMessage in tdMessages.reversed() {
            mappedMessages.append(await mapMessage(tdMessage, in: chat))
        }
        return mappedMessages
    }

    func loadContacts() async throws -> [Contact] {
        []
    }

    func loadChannels() async throws -> [Channel] {
        []
    }

    func loadCalls() async throws -> [CallRecord] {
        []
    }

    func sendText(_ text: String, chatID: Int64) async throws -> Message {
        let content = InputMessageContent.inputMessageText(
            InputMessageText(
                clearDraft: true,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: text)
            )
        )

        let sent: TDLibKit.Message = try await runTDLibRequest { completion in
            try tdClient.sendMessage(
                chatId: chatID,
                inputMessageContent: content,
                options: nil,
                replyMarkup: nil,
                replyTo: nil,
                topicId: nil,
                completion: completion
            )
        }

        return await mapMessage(sent)
    }

    func sendVoiceMessage(duration: TimeInterval, chatID: Int64) async throws -> Message {
        throw TDLibTelegramClientError.unsupportedVoiceMessagePlaceholder
    }

    private var tdClient: TDLibClient {
        get throws {
            guard let client else {
                throw TDLibTelegramClientError.clientNotStarted
            }
            return client
        }
    }

    private func prepareStorage() throws {
        try FileManager.default.createDirectory(
            atPath: configuration.databaseDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: configuration.filesDirectory,
            withIntermediateDirectories: true
        )
    }

    private func configureTDLibLogging(for client: TDLibClient) {
        try? client.setLogStream(logStream: .logStreamEmpty, completion: ignoreTDLibOKResult)
        try? client.setLogVerbosityLevel(newVerbosityLevel: 1, completion: ignoreTDLibOKResult)
    }

    private func loadLatestMessages(chatID: Int64) async throws -> Messages {
        try await runTDLibRequest { completion in
            try tdClient.getChatHistory(
                chatId: chatID,
                fromMessageId: 0,
                limit: 100,
                offset: 0,
                onlyLocal: false,
                completion: completion
            )
        }
    }

    fileprivate func handleUpdateData(_ data: Data, client: TDLibClient) {
        if isIgnoredUpdate(data) {
            return
        }

        do {
            let update = try client.decoder.decode(Update.self, from: data)
            handle(update)
        } catch {
            print("TDLib update decode failed: \(error)")
        }
    }

    private func isIgnoredUpdate(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        return json["@type"] as? String == "updateOption"
    }

    private func handle(_ update: Update) {
        switch update {
        case .updateAuthorizationState(let authorizationState):
            handleAuthorizationState(authorizationState.authorizationState)
        case .updateNewChat(let update):
            chatCache[update.chat.id] = update.chat
        case .updateChatLastMessage(let update):
            chatLastMessageCache[update.chatId] = update.lastMessage
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let conversations = try? await fetchChats() {
                    continuation.yield(.chatsChanged(conversations))
                }
            }
        case .updateNewMessage(let update):
            Task { @MainActor [weak self] in
                guard let self else { return }
                let message = await mapMessage(update.message)
                continuation.yield(.messagesChanged(chatID: update.message.chatId, messages: [message]))
            }
        default:
            break
        }
    }

    private func handleAuthorizationState(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            continuation.yield(.authorizationStateChanged(.waitingForParameters))
            Task { @MainActor [weak self] in
                try? await self?.sendTDLibParameters()
            }
        case .authorizationStateWaitPhoneNumber:
            continuation.yield(.authorizationStateChanged(.waitingForPhoneNumber))
        case .authorizationStateWaitCode:
            continuation.yield(.authorizationStateChanged(.waitingForCode))
        case .authorizationStateWaitPassword:
            continuation.yield(.authorizationStateChanged(.waitingForPassword))
        case .authorizationStateReady:
            continuation.yield(.authorizationStateChanged(.ready))
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let chats = try? await loadChats() {
                    continuation.yield(.chatsChanged(chats))
                }
            }
        case .authorizationStateLoggingOut:
            continuation.yield(.authorizationStateChanged(.loggingOut))
        case .authorizationStateClosed:
            continuation.yield(.authorizationStateChanged(.closed))
        default:
            continuation.yield(.authorizationStateChanged(.unknown(String(describing: state))))
        }
    }

    private func sendTDLibParameters() async throws {
        let _: Ok = try await runTDLibRequest { completion in
            try tdClient.setTdlibParameters(
                apiHash: configuration.apiHash,
                apiId: configuration.apiID,
                applicationVersion: "0.1.0",
                databaseDirectory: configuration.databaseDirectory,
                databaseEncryptionKey: Data(),
                deviceModel: "Mac",
                filesDirectory: configuration.filesDirectory,
                systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
                systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                useChatInfoDatabase: true,
                useFileDatabase: true,
                useMessageDatabase: true,
                useSecretChats: true,
                useTestDc: configuration.useTestDataCenter,
                completion: completion
            )
        }
    }

    private func loadChat(id: Int64) async throws -> TDLibKit.Chat {
        if let chat = chatCache[id] {
            return chat
        }

        return try await fetchChat(id: id)
    }

    private func fetchChat(id: Int64) async throws -> TDLibKit.Chat {
        let chat: TDLibKit.Chat = try await runTDLibRequest { completion in
            try tdClient.getChat(chatId: id, completion: completion)
        }
        chatCache[id] = chat
        return chat
    }

    private func mapConversation(_ chat: TDLibKit.Chat) -> Conversation {
        let lastMessage: TDLibKit.Message?
        if let cached = chatLastMessageCache[chat.id] {
            lastMessage = cached
        } else {
            lastMessage = chat.lastMessage
        }
        return Conversation(
            id: chat.id,
            title: chat.title,
            subtitle: messagePreview(lastMessage),
            time: formatDate(lastMessage?.date),
            unreadCount: chat.unreadCount,
            isPinned: chat.positions.contains { $0.isPinned },
            isMuted: chat.notificationSettings.muteFor > 0
        )
    }

    private func mapMessage(_ tdMessage: TDLibKit.Message, in chat: TDLibKit.Chat? = nil) async -> Message {
        Message(
            sender: await senderName(for: tdMessage),
            time: formatDate(tdMessage.date),
            isOutgoing: tdMessage.isOutgoing,
            kind: messageKind(tdMessage.content),
            outgoingStatus: outgoingStatus(for: tdMessage, in: chat)
        )
    }

    private func messageKind(_ content: MessageContent) -> MessageKind {
        switch content {
        case .messageText(let text):
            return .text(text.text.text)
        case .messageVoiceNote(let voiceNote):
            let transcript = voiceTranscript(voiceNote)
            return .voice(duration: TimeInterval(voiceNote.voiceNote.duration), transcript: transcript)
        default:
            let summary = mediaSummary(content)
            return .media(icon: summary.icon, label: summary.label)
        }
    }

    private func messagePreview(_ message: TDLibKit.Message?) -> String {
        guard let message else { return "No messages yet" }
        switch message.content {
        case .messageText(let text):
            return text.text.text
        case .messageVoiceNote(let voiceNote):
            return "Voice message, \(Message.format(TimeInterval(voiceNote.voiceNote.duration)))"
        default:
            return mediaSummary(message.content).label
        }
    }

    /// Extracts a recognized voice transcript only from a finalized recognition result;
    /// pending/error results fall back to the caption (avoids dumping the enum value).
    private func voiceTranscript(_ voiceNote: MessageVoiceNote) -> String {
        let recognized: String
        switch voiceNote.voiceNote.speechRecognitionResult {
        case .speechRecognitionResultText(let result):
            recognized = result.text
        default:
            recognized = voiceNote.caption.text
        }
        return recognized.isEmpty ? "No transcript available." : recognized
    }

    /// Maps any non-text/non-voice content to a clean SF Symbol + human label (with caption
    /// appended where the content type carries one). Never produces a reflection dump — the
    /// `default` arm returns a generic "Message" for service/poll/location/etc.
    private func mediaSummary(_ content: MessageContent) -> (icon: String, label: String) {
        func withCaption(_ base: String, _ caption: FormattedText) -> String {
            caption.text.isEmpty ? base : "\(base) — \(caption.text)"
        }

        switch content {
        case .messagePhoto(let photo):
            return ("photo", withCaption("Photo", photo.caption))
        case .messageVideo(let video):
            let base = "Video, \(Message.format(TimeInterval(video.video.duration)))"
            return ("video", withCaption(base, video.caption))
        case .messageAnimation(let animation):
            return ("photo", withCaption("GIF", animation.caption))
        case .messageSticker(let sticker):
            let emoji = sticker.sticker.emoji
            return ("face.smiling", emoji.isEmpty ? "Sticker" : "Sticker \(emoji)")
        case .messageDocument(let document):
            let name = document.document.fileName
            return ("doc", name.isEmpty ? "Document" : "Document \(name)")
        case .messageAudio(let audio):
            let track = audio.audio
            let title = track.title.isEmpty ? track.fileName : track.title
            let base = track.performer.isEmpty ? "Audio \(title)" : "Audio \(track.performer) — \(title)"
            return ("music.note", withCaption(base, audio.caption))
        default:
            return ("doc.text", "Message")
        }
    }

    private func outgoingStatus(for message: TDLibKit.Message, in chat: TDLibKit.Chat?) -> OutgoingMessageStatus? {
        guard message.isOutgoing else { return nil }
        if message.sendingState != nil {
            return .sent
        }
        if let chat, message.id <= chat.lastReadOutboxMessageId {
            return .read
        }
        return .delivered
    }

    private func senderName(for message: TDLibKit.Message) async -> String {
        if message.isOutgoing {
            return "You"
        }

        switch message.senderId {
        case .messageSenderUser(let sender):
            if let user = userCache[sender.userId] {
                return displayName(for: user)
            }

            if let user: TDLibKit.User = try? await runTDLibRequest({ completion in
                try tdClient.getUser(userId: sender.userId, completion: completion)
            }) {
                userCache[sender.userId] = user
                return displayName(for: user)
            }

            return "User \(sender.userId)"
        case .messageSenderChat(let sender):
            if let chat = try? await loadChat(id: sender.chatId) {
                return chat.title
            }
            return "Chat \(sender.chatId)"
        }
    }

    private func displayName(for user: TDLibKit.User) -> String {
        [user.firstName, user.lastName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func formatDate(_ timestamp: Int?) -> String {
        guard let timestamp, timestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func runTDLibRequest<ResultType: Sendable>(
        _ request: (@escaping (Result<ResultType, Swift.Error>) -> Void) throws -> Void
    ) async throws -> ResultType {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try request { result in
                    continuation.resume(with: result)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func ignoreTDLibOKResult(_ result: Result<Ok, Swift.Error>) {}

private final class TDLibUpdateBridge: @unchecked Sendable {
    @MainActor private weak var owner: TDLibTelegramClient?

    @MainActor
    init(owner: TDLibTelegramClient) {
        self.owner = owner
    }

    nonisolated func handle(data: Data, client: TDLibClient) {
        Task { @MainActor [weak self] in
            self?.owner?.handleUpdateData(data, client: client)
        }
    }
}
