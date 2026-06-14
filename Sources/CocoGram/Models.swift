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
    /// A still image to render inline: a photo or a (static) sticker.
    case image(ImageMedia)
    /// A video or animation: a still poster is shown, played inline on demand (never autoplays).
    case video(VideoMedia)
    /// Any remaining non-renderable content (document, audio, contact, service, etc.).
    /// `icon` is an SF Symbol name; `label` is a self-contained human description
    /// (already including any caption) so it reads naturally on its own to VoiceOver.
    case media(icon: String, label: String)

    var accessibilityText: String {
        switch self {
        case .text(let body):
            return body
        case .voice(let duration, let transcript, _):
            return "Voice message, \(Message.format(duration)), transcript: \(transcript)"
        case .image(let image):
            return image.accessibilityLabel
        case .video(let video):
            return video.accessibilityLabel
        case .media(_, let label):
            return label
        }
    }
}

/// A still image (photo or static sticker) rendered inline in the conversation. `fileID` is
/// the TDLib file to download and display; `width`/`height` are the intrinsic pixel size used
/// to lay the cell out at the right aspect ratio before the bytes arrive.
struct ImageMedia: Equatable {
    let fileID: Int
    let width: Int
    let height: Int
    /// Caption shown beneath the image (empty when there is none).
    let caption: String
    /// Self-contained VoiceOver description, e.g. "Photo" or "Sticker 🐺" (+ caption).
    let accessibilityLabel: String
}

/// A video or animation. The `posterFileID` thumbnail renders immediately (and is cheap to
/// fetch); the full `videoFileID` is downloaded and cached only when the user clicks play —
/// nothing ever autoplays. `width`/`height` lay out the poster at the right aspect ratio.
struct VideoMedia: Equatable {
    let videoFileID: Int
    let posterFileID: Int?
    let width: Int
    let height: Int
    let duration: TimeInterval
    let caption: String
    let accessibilityLabel: String
}

enum OutgoingMessageStatus: String {
    case sent = "sent"
    case delivered = "delivered"
    case read = "read"
    case played = "played"
}

struct Message {
    /// TDLib message identifier, used to anchor older-history pagination (load messages
    /// before this id). 0 for locally-synthesized messages that were never assigned one.
    let id: Int64
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

/// The media connection material TDLib hands back when a call reaches `ready` — the shared key,
/// the SAS emoji fingerprint both peers verify aloud, and the tgcalls config/parameters that
/// carry the reflector endpoints. The call media engine consumes these.
/// A Telegram reflector relay endpoint the media engine can send encrypted voice packets to.
struct CallReflectorServer: Equatable {
    let host: String
    let port: UInt16
    /// 16-byte routing tag prefixed (unencrypted) to every packet sent through this reflector.
    let peerTag: Data
    let isTcp: Bool
}

struct CallConnection: Equatable {
    let encryptionKey: Data
    let config: String
    let customParameters: String
    /// 4-emoji Short Authentication String shown to both parties to confirm no MITM.
    let emojis: [String]
    /// Reflector relays parsed from TDLib's structured `servers` list.
    let reflectors: [CallReflectorServer]
}

/// A 1:1 Telegram call's lifecycle state, mapped from TDLib's `CallState` into a UI-facing value.
enum CocoCallState: Equatable {
    case pending(isOutgoing: Bool, isReceived: Bool)
    case exchangingKeys
    case ready(CallConnection)
    case hangingUp
    case discarded(reason: String)
    case failed(String)
}

/// A 1:1 call, mapped from TDLib's `Call` so the UI never imports TDLibKit types directly.
struct CocoCall: Equatable {
    let id: Int
    let userID: Int64
    let isOutgoing: Bool
    let isVideo: Bool
    let state: CocoCallState
    var peerName: String

    var accessibilitySummary: String {
        let direction = isOutgoing ? "Outgoing" : "Incoming"
        let kind = isVideo ? "video call" : "audio call"
        let status: String
        switch state {
        case .pending: status = isOutgoing ? "calling" : "ringing"
        case .exchangingKeys: status = "connecting"
        case .ready: status = "connected"
        case .hangingUp: status = "ending"
        case .discarded(let reason): status = "ended, \(reason)"
        case .failed(let message): status = "failed, \(message)"
        }
        return "\(direction) \(kind) with \(peerName), \(status)"
    }
}

struct Conversation: Equatable {
    let id: Int64
    let title: String
    let subtitle: String
    let time: String
    let unreadCount: Int
    let isPinned: Bool
    let isMuted: Bool
}

struct Contact: Equatable {
    let name: String
    let status: String
    let handle: String
}

struct Channel: Equatable {
    let title: String
    let members: String
    let preview: String
}

struct CallRecord: Equatable {
    let name: String
    let status: String
    let time: String
    let missed: Bool
}

enum DetailItem: Equatable {
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
