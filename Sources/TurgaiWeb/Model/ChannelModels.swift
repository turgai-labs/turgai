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

struct ChannelUpdateFormValues: Sendable, Equatable {
    let id: String
    let label: String
    let enabled: Bool
    let chatIDs: String?
    let token: String?
    /// Empty means default routing.
    let agentProfileID: String?

    init(form: [String: [String]]) {
        id = form["id"]?.first ?? ""
        label = form["label"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        enabled = form["enabled"] != nil
        chatIDs = form["chatIDs"]?.first
        token = form["token"]?.first
        let rawProfileID =
            form["agentProfileID"]?.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        agentProfileID = rawProfileID.isEmpty ? nil : rawProfileID
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

struct ChannelEditItem: Sendable, Equatable {
    let id: UUID
    let label: String
    let enabled: Bool
    let chatIDs: [Int64]
    let hasToken: Bool
    let agentProfileID: String?
}
