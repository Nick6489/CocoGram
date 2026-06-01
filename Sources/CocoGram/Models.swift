import Foundation

enum NavigationSection: String, CaseIterable {
    case chats = "Chats"
    case contacts = "Contacts"
    case channels = "Channels"
    case calls = "Calls"

    var icon: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right.fill"
        case .contacts: return "person.2.fill"
        case .channels: return "megaphone.fill"
        case .calls: return "phone.fill"
        }
    }
}

enum MessageKind {
    case text(String)
    case voice(duration: TimeInterval, transcript: String, fileID: Int?)
    /// Any non-text, non-voice content (photo, video, sticker, document, audio, etc.).
    /// `icon` is an SF Symbol name; `label` is a self-contained human description
    /// (already including any caption) so it reads naturally on its own to VoiceOver.
    case media(icon: String, label: String)

    var accessibilityText: String {
        switch self {
        case .text(let body):
            return body
        case .voice(let duration, let transcript, _):
            return "Voice message, \(Message.format(duration)), transcript: \(transcript)"
        case .media(_, let label):
            return label
        }
    }
}

enum OutgoingMessageStatus: String {
    case sent = "sent"
    case delivered = "delivered"
    case read = "read"
    case played = "played"
}

struct Message {
    let sender: String
    let time: String
    let isOutgoing: Bool
    let kind: MessageKind
    let outgoingStatus: OutgoingMessageStatus?

    var accessibilitySummary: String {
        let person = isOutgoing ? "You" : sender
        let coreSummary = "\(person), \(kind.accessibilityText), \(time)"

        if isOutgoing, let outgoingStatus {
            return "\(coreSummary), \(outgoingStatus.rawValue)"
        }

        return coreSummary
    }

    static func format(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return "\(seconds / 60) minutes \(seconds % 60) seconds"
    }
}

struct Conversation {
    let id: Int64
    let title: String
    let subtitle: String
    let time: String
    let unreadCount: Int
    let isPinned: Bool
    let isMuted: Bool
}

struct Contact {
    let name: String
    let status: String
    let handle: String
}

struct Channel {
    let title: String
    let members: String
    let preview: String
}

struct CallRecord {
    let name: String
    let status: String
    let time: String
    let missed: Bool
}

enum DetailItem {
    case conversation(Conversation)
    case contact(Contact)
    case channel(Channel)
    case call(CallRecord)

    var title: String {
        switch self {
        case .conversation(let conversation): return conversation.title
        case .contact(let contact): return contact.name
        case .channel(let channel): return channel.title
        case .call(let call): return call.name
        }
    }

    var subtitle: String {
        switch self {
        case .conversation(let conversation): return conversation.subtitle
        case .contact(let contact): return "\(contact.handle) - \(contact.status)"
        case .channel(let channel): return "\(channel.members) subscribers"
        case .call(let call): return "\(call.status) - \(call.time)"
        }
    }

    var accessibilitySummary: String {
        "\(title), \(subtitle)"
    }
}
