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

    /// Filename of the per-session credential pin, stored inside the database directory.
    private static let pinFileName = "session.pin"

    /// Resolves the TDLib configuration.
    ///
    /// INVARIANT (see `SESSION_PERSISTENCE_INVARIANT.md`): a logged-in user must never be
    /// forced to re-authenticate. Two rules enforce that here:
    ///  - RULE A — the database path is FIXED. It never depends on api_id, the test-DC flag,
    ///    the working directory, the environment, or which binary is running. Every launch of
    ///    every build resolves the same directory, so the session is never abandoned.
    ///  - RULE B — once a session exists, the credentials PINNED into its database directory
    ///    are authoritative. Launch-time config (`.cocogram.local`, `credentials.conf`, env)
    ///    is consulted ONLY to bootstrap the very first login. Reusing the exact api_id the
    ///    session was created with is what stops Telegram from revoking it.
    static func resolve() -> TDLibConfiguration? {
        var values = savedConfiguration()
        values.merge(localConfiguration()) { _, new in new }
        values.merge(ProcessInfo.processInfo.environment) { _, new in new }

        // RULE A: fixed path. The only permitted variation is an explicit dev override.
        let databaseDirectory = values["COCOGRAM_TDLIB_DATABASE"] ?? defaultDatabaseDirectory()
        let filesDirectory = values["COCOGRAM_TDLIB_FILES"] ?? defaultFilesDirectory()

        // RULE B: a pinned session's credentials win, unconditionally.
        if let pinned = readPinnedCredentials(inDatabaseDirectory: databaseDirectory) {
            return TDLibConfiguration(
                apiID: pinned.apiID,
                apiHash: pinned.apiHash,
                databaseDirectory: databaseDirectory,
                filesDirectory: filesDirectory,
                useTestDataCenter: pinned.useTestDataCenter
            )
        }

        // First login only: bootstrap credentials from config sources.
        guard
            let apiIDString = values["COCOGRAM_API_ID"],
            let apiID = Int(apiIDString),
            let apiHash = values["COCOGRAM_API_HASH"],
            !apiHash.isEmpty
        else {
            return nil
        }

        return TDLibConfiguration(
            apiID: apiID,
            apiHash: apiHash,
            databaseDirectory: databaseDirectory,
            filesDirectory: filesDirectory,
            useTestDataCenter: values["COCOGRAM_TDLIB_TEST_DC"] == "1"
        )
    }

    /// The fixed, launch-invariant TDLib database directory. Never keyed on api_id, cwd, or
    /// environment — see `SESSION_PERSISTENCE_INVARIANT.md` (RULE A).
    private static func defaultDatabaseDirectory() -> String {
        appSupportDirectory()
            .appendingPathComponent("tdlib", isDirectory: true)
            .appendingPathComponent("database", isDirectory: true).path
    }

    private static func defaultFilesDirectory() -> String {
        appSupportDirectory()
            .appendingPathComponent("tdlib", isDirectory: true)
            .appendingPathComponent("files", isDirectory: true).path
    }

    private static func pinURL(inDatabaseDirectory databaseDirectory: String) -> URL {
        URL(fileURLWithPath: databaseDirectory).appendingPathComponent(pinFileName)
    }

    private static func readPinnedCredentials(inDatabaseDirectory databaseDirectory: String)
        -> (apiID: Int, apiHash: String, useTestDataCenter: Bool)? {
        let values = parseKeyValueFile(at: pinURL(inDatabaseDirectory: databaseDirectory))
        guard
            let apiIDString = values["COCOGRAM_API_ID"],
            let apiID = Int(apiIDString),
            let apiHash = values["COCOGRAM_API_HASH"],
            !apiHash.isEmpty
        else {
            return nil
        }
        return (apiID, apiHash, values["COCOGRAM_TDLIB_TEST_DC"] == "1")
    }

    /// Pins the credentials of an established session into its database directory so every
    /// future launch — any build, any working directory — reuses them. Called once auth
    /// reaches Ready (the credentials are proven good). Never overwrites an existing pin.
    /// See `SESSION_PERSISTENCE_INVARIANT.md` (RULE B).
    static func pinSessionCredentials(_ configuration: TDLibConfiguration) {
        let url = pinURL(inDatabaseDirectory: configuration.databaseDirectory)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        var lines = [
            "# Written by CocoGram. Pins the credentials this Telegram session was created",
            "# with so they are reused on every launch and the session is never lost. Delete",
            "# this file (or the database directory) to force a fresh login. See",
            "# SESSION_PERSISTENCE_INVARIANT.md.",
            "COCOGRAM_API_ID=\(configuration.apiID)",
            "COCOGRAM_API_HASH=\(configuration.apiHash)"
        ]
        if configuration.useTestDataCenter {
            lines.append("COCOGRAM_TDLIB_TEST_DC=1")
        }
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Clears the pin so newly-entered credentials take effect on the next launch. Called
    /// ONLY when the user deliberately saves credentials via the setup screen (an account
    /// switch) — never on a normal launch.
    static func clearSessionCredentialPin() {
        try? FileManager.default.removeItem(at: pinURL(inDatabaseDirectory: defaultDatabaseDirectory()))
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

        // The user deliberately chose these credentials, so drop any existing pin: this is
        // the one sanctioned path for switching the api_id, and the new credentials must
        // take effect on the next launch. See SESSION_PERSISTENCE_INVARIANT.md.
        clearSessionCredentialPin()
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

    var errorDescription: String? {
        switch self {
        case .clientNotStarted:
            return "TDLib client has not been started."
        }
    }
}

final class TDLibTelegramClient: TelegramClient {
    /// All TDLib clients in the process must share one manager: every manager starts its
    /// own thread looping the process-global `td_receive`, and TDLib aborts when two
    /// threads call receive concurrently (and whichever loop wins would silently discard
    /// the other manager's events). Created lazily so dummy-mode runs never start a
    /// TDLib receive thread.
    private static var _sharedManager: TDLibClientManager?
    private static var sharedManager: TDLibClientManager {
        if let manager = _sharedManager { return manager }
        let manager = TDLibClientManager()
        _sharedManager = manager
        return manager
    }

    /// Blocks until every TDLib client has flushed its database and closed. Call only
    /// from `applicationWillTerminate`; individual sessions end via `stop()`.
    static func shutdownAllClients() {
        _sharedManager?.closeClients()
    }

    let updates: AsyncStream<TelegramUpdate>

    private let continuation: AsyncStream<TelegramUpdate>.Continuation
    private let configuration: TDLibConfiguration
    private lazy var updateBridge = TDLibUpdateBridge(owner: self)
    private var client: TDLibClient?
    private var chatCache: [Int64: TDLibKit.Chat] = [:]
    private var userCache: [Int64: TDLibKit.User] = [:]
    private var chatLastMessageCache: [Int64: TDLibKit.Message?] = [:]
    private var pendingVoiceUploadURLs: [Int: URL] = [:]
    private var isStopping = false
    private var needsChatsRefresh = false
    private var isChatsRefreshRunning = false

    init(configuration: TDLibConfiguration) {
        self.configuration = configuration
        let stream = AsyncStream<TelegramUpdate>.makeStream()
        updates = stream.stream
        continuation = stream.continuation
    }

    func start() async throws {
        guard !isStopping else { return }
        try prepareStorage()
        if client == nil {
            let updateBridge = updateBridge
            let newClient = Self.sharedManager.createClient(updateHandler: updateBridge.handle(data:client:))
            configureTDLibLogging(for: newClient)
            client = newClient
        }
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        for fileID in Array(pendingVoiceUploadURLs.keys) {
            removePendingVoiceUpload(fileID: fileID)
        }
        // Close only this instance's client — the shared manager may already be running
        // a replacement session. The blocking flush-everything wait lives in
        // `shutdownAllClients()` and happens once, at app termination.
        //
        // The completion MUST be the nonisolated `ignoreTDLibOKResult`, not a `{ _ in }`
        // literal: a closure formed in this @MainActor method is @MainActor-isolated, and
        // TDLibKit invokes the close completion later on its background update-handler
        // queue. Swift's isolation precondition then traps (EXC_BREAKPOINT) for using a
        // main-actor closure off the main thread — which crashed the app ~30s after quit,
        // once TDLib finished flushing and delivered the close response.
        if let client {
            try? client.close(completion: ignoreTDLibOKResult)
        }
        client = nil
        continuation.finish()
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

    func downloadVoiceMessage(fileID: Int) async throws -> URL {
        let file: TDLibKit.File = try await runTDLibRequest { completion in
            try tdClient.downloadFile(
                fileId: fileID,
                limit: 0,
                offset: 0,
                priority: 32,
                synchronous: true,
                completion: completion
            )
        }
        guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else {
            throw CocoaError(.fileReadUnknown)
        }
        return URL(fileURLWithPath: file.local.path)
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

    func sendVoiceMessage(fileURL: URL, duration: TimeInterval, chatID: Int64) async throws -> Message {
        var uploadedFileID: Int?
        do {
            let uploadedFile: TDLibKit.File = try await runTDLibRequest { completion in
                try tdClient.preliminaryUploadFile(
                    file: .inputFileLocal(InputFileLocal(path: fileURL.path)),
                    fileType: .fileTypeVoiceNote,
                    priority: 32,
                    completion: completion
                )
            }
            uploadedFileID = uploadedFile.id
            retainVoiceUpload(fileURL, for: uploadedFile.id)

            let content = InputMessageContent.inputMessageVoiceNote(
                InputMessageVoiceNote(
                    caption: nil,
                    duration: max(Int(duration.rounded(.up)), 1),
                    selfDestructType: nil,
                    voiceNote: .inputFileId(InputFileId(id: uploadedFile.id)),
                    waveform: Data()
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
        } catch {
            if let uploadedFileID {
                removePendingVoiceUpload(fileID: uploadedFileID)
            } else {
                try? FileManager.default.removeItem(at: fileURL)
            }
            throw error
        }
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

    /// Keeps warnings and errors in a rotating file next to the database. The failures
    /// behind a "logged in yesterday, asked for my phone number today" report happen
    /// inside TDLib (revoked sessions, database lock contention) and are otherwise
    /// invisible after the fact.
    private func configureTDLibLogging(for client: TDLibClient) {
        let logPath = URL(fileURLWithPath: configuration.databaseDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("tdlib.log")
            .path
        let stream = LogStream.logStreamFile(
            LogStreamFile(maxFileSize: 5 * 1024 * 1024, path: logPath, redirectStderr: false)
        )
        try? client.setLogStream(logStream: stream, completion: ignoreTDLibOKResult)
        try? client.setLogVerbosityLevel(newVerbosityLevel: 2, completion: ignoreTDLibOKResult)
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
            scheduleChatsRefresh()
        case .updateNewMessage(let update):
            Task { @MainActor [weak self] in
                guard let self else { return }
                let message = await mapMessage(update.message)
                continuation.yield(.messagesChanged(chatID: update.message.chatId, messages: [message]))
            }
        case .updateFile(let update):
            if update.file.remote.isUploadingCompleted {
                removePendingVoiceUpload(fileID: update.file.id)
            }
        default:
            break
        }
    }

    private func retainVoiceUpload(_ url: URL, for fileID: Int) {
        pendingVoiceUploadURLs[fileID] = url
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3600))
            self?.removePendingVoiceUpload(fileID: fileID)
        }
    }

    private func removePendingVoiceUpload(fileID: Int) {
        guard let url = pendingVoiceUploadURLs.removeValue(forKey: fileID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func handleAuthorizationState(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            continuation.yield(.authorizationStateChanged(.waitingForParameters))
            Task { @MainActor [weak self] in
                await self?.sendTDLibParametersReportingFailure()
            }
        case .authorizationStateWaitPhoneNumber:
            continuation.yield(.authorizationStateChanged(.waitingForPhoneNumber))
        case .authorizationStateWaitCode:
            continuation.yield(.authorizationStateChanged(.waitingForCode))
        case .authorizationStateWaitPassword:
            continuation.yield(.authorizationStateChanged(.waitingForPassword))
        case .authorizationStateReady:
            // Pin the credentials this now-established session was created with, so every
            // future launch reuses them and the session is never lost. See
            // SESSION_PERSISTENCE_INVARIANT.md.
            TDLibConfiguration.pinSessionCredentials(configuration)
            continuation.yield(.authorizationStateChanged(.ready))
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let chats = try? await loadChats() {
                    continuation.yield(.chatsChanged(chats))
                }
            }
        case .authorizationStateLoggingOut:
            continuation.yield(.authorizationStateChanged(.loggingOut))
        case .authorizationStateClosing:
            // Transient while TDLib shuts down; `closed` follows and is what matters.
            break
        case .authorizationStateClosed:
            continuation.yield(.authorizationStateChanged(.closed))
            if !isStopping {
                // TDLib closed itself (it does this after a server-side logout, having
                // destroyed the database). The instance is dead: TDLibKit drops responses
                // for closed clients, so any further request would hang its caller
                // forever. Failing fast lets the owner build a fresh client and restart
                // the sign-in flow.
                client = nil
                continuation.finish()
            }
        default:
            continuation.yield(.authorizationStateChanged(.unknown(humanReadableStateName(state))))
        }
    }

    /// "authorizationStateWaitEmailCode(...)" reads as a code dump over VoiceOver;
    /// reduce it to plain words ("wait email code").
    private func humanReadableStateName(_ state: AuthorizationState) -> String {
        let caseName = String(describing: state)
            .prefix(while: { $0 != "(" })
            .replacingOccurrences(of: "authorizationState", with: "")
        var words = ""
        for character in caseName {
            if character.isUppercase, !words.isEmpty {
                words.append(" ")
            }
            words.append(Character(character.lowercased()))
        }
        return words
    }

    /// `setTdlibParameters` failures would otherwise strand TDLib in
    /// `waitTdlibParameters` with a normal-looking, permanently empty window. Lock
    /// contention — a previous instance still holding the database while it finishes
    /// quitting — is the one transient cause, so only it is retried (each attempt blocks
    /// ~10s inside TDLib's own lock wait) and the user hears that a retry is underway.
    /// Everything else is permanent and reported immediately.
    private func sendTDLibParametersReportingFailure() async {
        var lastError: Swift.Error?
        for attempt in 1...3 {
            guard !isStopping else { return }
            do {
                try await sendTDLibParameters()
                return
            } catch {
                lastError = error
                guard isDatabaseLockError(error) else { break }
                if attempt == 1 {
                    continuation.yield(.startupStalled(
                        message: "Telegram's local database is in use — another copy of CocoGram may still be closing. Retrying."
                    ))
                }
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }

        let description: String
        if let tdError = lastError as? TDLibKit.Error {
            description = tdError.message
        } else {
            description = lastError?.localizedDescription ?? "Unknown error"
        }
        continuation.yield(.startupFailed(message: description))
    }

    private func isDatabaseLockError(_ error: Swift.Error) -> Bool {
        guard let tdError = error as? TDLibKit.Error else { return false }
        return tdError.message.localizedCaseInsensitiveContains("lock")
    }

    private func scheduleChatsRefresh() {
        // TDLib delivers updateChatLastMessage in bursts (several per chat during the
        // initial sync). A single coalescing loop keeps at most one chat-list fetch in
        // flight and always finishes on the newest state — per-update fetches would
        // flood the main actor, and overlapping fetches can complete out of order,
        // letting an older snapshot overwrite a newer one.
        needsChatsRefresh = true
        guard !isChatsRefreshRunning else { return }
        isChatsRefreshRunning = true
        Task { @MainActor [weak self] in
            while true {
                guard let self, !self.isStopping, self.needsChatsRefresh else { break }
                self.needsChatsRefresh = false
                try? await Task.sleep(for: .milliseconds(300))
                if let conversations = try? await self.fetchChats() {
                    self.continuation.yield(.chatsChanged(conversations))
                }
            }
            self?.isChatsRefreshRunning = false
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
            return .voice(
                duration: TimeInterval(voiceNote.voiceNote.duration),
                transcript: transcript,
                fileID: voiceNote.voiceNote.voice.id
            )
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
