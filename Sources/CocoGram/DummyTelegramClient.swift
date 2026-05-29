import Foundation

final class DummyTelegramClient: TelegramClient {
    let updates: AsyncStream<TelegramUpdate>

    private let continuation: AsyncStream<TelegramUpdate>.Continuation
    private var conversations: [Conversation]
    private var messagesByChatID: [Int64: [Message]]
    private let contacts: [Contact]
    private let channels: [Channel]
    private let calls: [CallRecord]

    init() {
        let stream = AsyncStream<TelegramUpdate>.makeStream()
        updates = stream.stream
        continuation = stream.continuation

        conversations = [
            Conversation(
                id: 1,
                title: "Design Team",
                subtitle: "Maya: Voice note about onboarding",
                time: "9:42 AM",
                unreadCount: 3,
                isPinned: true,
                isMuted: false
            ),
            Conversation(
                id: 2,
                title: "TDLib Integration",
                subtitle: "Sam: Mock auth state until backend lands",
                time: "Yesterday",
                unreadCount: 0,
                isPinned: true,
                isMuted: true
            ),
            Conversation(
                id: 3,
                title: "Family",
                subtitle: "Nico: Call me after dinner?",
                time: "Mon",
                unreadCount: 1,
                isPinned: false,
                isMuted: false
            )
        ]

        messagesByChatID = [
            1: [
                Message(sender: "Maya", time: "9:31 AM", isOutgoing: false, kind: .text("Can we make the first-run flow friendly for VoiceOver from day one?"), outgoingStatus: nil),
                Message(sender: "Maya", time: "9:33 AM", isOutgoing: false, kind: .voice(duration: 42, transcript: "I walked through the contact picker and the order feels right. The compose field should announce attachment state."), outgoingStatus: nil),
                Message(sender: "You", time: "9:38 AM", isOutgoing: true, kind: .text("Yes. I am adding labels and actions directly to the controls instead of treating accessibility as a pass at the end."), outgoingStatus: .read)
            ],
            2: [
                Message(sender: "Sam", time: "Yesterday", isOutgoing: false, kind: .text("The UI can use fake chat identifiers for now. We will swap the source after TDLib client setup."), outgoingStatus: nil),
                Message(sender: "You", time: "Yesterday", isOutgoing: true, kind: .text("Great. I will keep the model shape close to Telegram concepts."), outgoingStatus: .delivered)
            ],
            3: [
                Message(sender: "Nico", time: "Monday", isOutgoing: false, kind: .text("Call me after dinner?"), outgoingStatus: nil),
                Message(sender: "You", time: "Monday", isOutgoing: true, kind: .text("Absolutely."), outgoingStatus: .sent)
            ]
        ]

        contacts = [
            Contact(name: "Maya Chen", status: "online", handle: "@maya"),
            Contact(name: "Sam Rivera", status: "last seen recently", handle: "@samr"),
            Contact(name: "Nico G.", status: "typing in Family", handle: "@nico")
        ]

        channels = [
            Channel(title: "Cocoa Accessibility", members: "14,208", preview: "New guide: labeling custom AppKit controls"),
            Channel(title: "Telegram Platform Updates", members: "2.1M", preview: "API layer update and TDLib release notes"),
            Channel(title: "Mac Indie Dev", members: "38,441", preview: "Friday demos and launch notes")
        ]

        calls = [
            CallRecord(name: "Maya Chen", status: "Outgoing audio call", time: "Today, 8:15 AM", missed: false),
            CallRecord(name: "Sam Rivera", status: "Missed video call", time: "Yesterday, 4:02 PM", missed: true),
            CallRecord(name: "Nico G.", status: "Incoming audio call", time: "Monday, 7:45 PM", missed: false)
        ]
    }

    func start() async throws {
        continuation.yield(.chatsChanged(conversations))
    }

    func submitPhoneNumber(_ phoneNumber: String) async throws {}

    func submitAuthenticationCode(_ code: String) async throws {}

    func submitPassword(_ password: String) async throws {}

    func loadChats() async throws -> [Conversation] {
        conversations
    }

    func loadMessages(chatID: Int64) async throws -> [Message] {
        messagesByChatID[chatID, default: []]
    }

    func loadContacts() async throws -> [Contact] {
        contacts
    }

    func loadChannels() async throws -> [Channel] {
        channels
    }

    func loadCalls() async throws -> [CallRecord] {
        calls
    }

    func sendText(_ text: String, chatID: Int64) async throws -> Message {
        let message = Message(sender: "You", time: "Just now", isOutgoing: true, kind: .text(text), outgoingStatus: .sent)
        messagesByChatID[chatID, default: []].append(message)
        continuation.yield(.messagesChanged(chatID: chatID, messages: messagesByChatID[chatID, default: []]))
        return message
    }

    func sendVoiceMessage(duration: TimeInterval, chatID: Int64) async throws -> Message {
        let message = Message(
            sender: "You",
            time: "Just now",
            isOutgoing: true,
            kind: .voice(duration: max(duration, 1), transcript: "Transcript pending for recorded voice message."),
            outgoingStatus: .sent
        )
        messagesByChatID[chatID, default: []].append(message)
        continuation.yield(.messagesChanged(chatID: chatID, messages: messagesByChatID[chatID, default: []]))
        return message
    }
}
