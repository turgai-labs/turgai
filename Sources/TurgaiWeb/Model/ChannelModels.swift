import TurgaiApplication

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct ChannelCreateFormValues: Sendable, Equatable {
    let kind: String
    let label: String

    init(form: [String: [String]]) {
        kind = form["kind"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        label = form["label"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// One selectable agent for a channel's routing.
struct ChannelBotOption: Sendable, Equatable {
    let id: String
    let name: String
}

/// Form-level validation that the store cannot perform itself (the bot
/// catalog lives in a different store).
enum ChannelFormError: Error {
    case unknownBot
    case unsupportedChannel
}

struct ChannelListItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let label: String
    let enabled: Bool
    let hasToken: Bool
    /// The bound bot's display name, nil for default routing.
    let botName: String?
}

/// A channel as its form shows it and sends it back: the saved one, or what was just submitted,
/// shown again when saving it failed.
struct ChannelDraft: Sendable, Equatable {
    let id: UUID
    var label: String
    var enabled: Bool
    var routing: ChannelAgentRouting
    /// The chats it listens to, comma-separated, as typed: empty is every chat.
    var chatIDs: String
    /// Whether a token is saved.
    var hasToken: Bool
    /// A new token typed now. Never shown back.
    var token: String
}

extension ChannelDraft {
    /// The saved `configuration`.
    init(_ configuration: ChannelConfiguration<TelegramProvider>, hasToken: Bool) {
        self.init(
            id: configuration.id, label: configuration.label, enabled: configuration.enabled,
            routing: configuration.agentRouting,
            chatIDs: configuration.provider.chatIDs.map(String.init).joined(separator: ","), hasToken: hasToken,
            token: "")
    }

    /// What was submitted, over `saved`.
    init(form: [String: [String]], over saved: ChannelDraft) {
        self = saved
        label = form["label"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? saved.label
        enabled = form["enabled"] != nil
        let profileID = (form["agentProfileID"]?.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        routing = profileID.isEmpty ? .defaultProfile : .profile(profileID)
        chatIDs = form["chatIDs"]?.first ?? saved.chatIDs
        token = (form["token"]?.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
