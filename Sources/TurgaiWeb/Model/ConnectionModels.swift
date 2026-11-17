import TurgaiApplication
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A new connection, as its form says: its platform, its label, and the space it's a way into.
struct ConnectionCreateFormValues: Sendable, Equatable {
    let kind: String
    let label: String

    init(form: [String: [String]]) {
        kind = form["kind"]?.first?.trimmed() ?? ""
        label = form["label"]?.first?.trimmed() ?? ""
    }
}

/// What the form says that can't be saved.
enum ConnectionFormError: Error {
    case unsupportedChannel
    /// A label that's empty or too long.
    case invalidLabel
}

/// One of a space's connections, as the list shows it.
struct ConnectionListItem: Identifiable, Sendable, Equatable {
    let id: ConnectionID
    let label: String
    let enabled: Bool
    let hasToken: Bool
    /// Why it stopped last, when it stopped by itself.
    let stopped: String?
}

/// A connection as its form shows it and sends it back: the saved one, or what was just
/// submitted, shown again when saving it failed.
struct ConnectionDraft: Sendable, Equatable {
    let id: ConnectionID
    var label: String
    var enabled: Bool
    /// The chats it listens to, comma-separated, as typed: empty is every chat.
    var chatIDs: String
    /// Whether a token is saved.
    var hasToken: Bool
    /// A new token typed now. Never shown back.
    var token: String
}

extension ConnectionDraft {
    /// The saved `connection`.
    init(_ connection: Connection, hasToken: Bool) {
        let chatIDs: [Int64] =
            switch connection.platform {
            case .telegram(let access): access.chatIDs
            }
        self.init(
            id: connection.id, label: connection.label.rawValue,
            enabled: connection.enabled, chatIDs: chatIDs.map(String.init).joined(separator: ","),
            hasToken: hasToken, token: "")
    }

    /// What was submitted, over `saved`.
    init(form: [String: [String]], over saved: ConnectionDraft) {
        self = saved
        label = form["label"]?.first?.trimmed() ?? saved.label
        enabled = form["enabled"] != nil
        chatIDs = form["chatIDs"]?.first ?? saved.chatIDs
        token = (form["token"]?.first ?? "").trimmed()
    }
}
