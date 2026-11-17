#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The signed-in person: their id, and what they're called.
public struct Me: Codable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A space's id, as the API names it.
public struct SpaceID: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What someone may do in a space: each area's level, none when they may do nothing there.
public struct SpacePermissions: Codable, Hashable, Sendable {
    /// Its people: seeing who's in it, or also managing them.
    public enum People: String, Codable, Hashable, Sendable {
        case see, manage
    }

    /// Its bots: using them, or also configuring them.
    public enum Bots: String, Codable, Hashable, Sendable {
        case use, configure
    }

    /// What's asked of it: answering, or also running anything without asking.
    public enum Requests: String, Codable, Hashable, Sendable {
        case answer, runAny
    }

    /// The tasks kept in it: seeing everyone's, or also changing them.
    public enum Tasks: String, Codable, Hashable, Sendable {
        case see, manage
    }

    public let people: People?
    public let bots: Bots?
    public let requests: Requests?
    public let tasks: Tasks?
    /// Configuring its connections.
    public let connections: Bool
    /// Deleting anyone's conversation in it.
    public let deleteConversations: Bool
    /// Naming and archiving it, and making its groups, what they may do, and its admins.
    public let configureSpace: Bool

    public init(
        people: People?, bots: Bots?, requests: Requests?, tasks: Tasks?, connections: Bool,
        deleteConversations: Bool, configureSpace: Bool
    ) {
        self.people = people
        self.bots = bots
        self.requests = requests
        self.tasks = tasks
        self.connections = connections
        self.deleteConversations = deleteConversations
        self.configureSpace = configureSpace
    }
}

/// A space the signed-in person is in, as their list shows it: what it's called, what they may do
/// in it, and whether it's in use.
public struct SpaceSummary: Codable, Hashable, Sendable, Identifiable {
    /// Whether it's in use. Archived, what's in it is read, and nothing new happens in it.
    public enum Status: String, Codable, Hashable, Sendable {
        case active
        case archived
    }

    public let id: SpaceID
    public let name: String
    public let permissions: SpacePermissions
    public let status: Status

    public init(id: SpaceID, name: String, permissions: SpacePermissions, status: Status) {
        self.id = id
        self.name = name
        self.permissions = permissions
        self.status = status
    }
}

/// Someone in a space, as another of its people sees them: their id, what they're called, and the
/// groups they're in.
public struct SpacePerson: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let groups: [String]

    public init(id: String, name: String, groups: [String]) {
        self.id = id
        self.name = name
        self.groups = groups
    }
}

/// A new space, called `name`, with `bot` its first bot: the one who asks is its first admin.
public struct MakeSpaceRequest: Codable, Hashable, Sendable {
    public let name: String
    public let bot: BotConfiguration

    public init(name: String, bot: BotConfiguration) {
        self.name = name
        self.bot = bot
    }
}

/// A bot as whoever configures it gives it: what it's called, what it's told, and what thinks for
/// it.
public struct BotConfiguration: Codable, Hashable, Sendable {
    public let name: String
    public let instructions: String
    public let model: ModelChoice

    public init(name: String, instructions: String, model: ModelChoice) {
        self.name = name
        self.instructions = instructions
        self.model = model
    }
}

/// Where a bot's model runs, and which of the models there: a provider, by its name; a server's
/// address, when it has one; a key typed now, which none keeps as it's saved; and the window chosen,
/// on a server of your own.
public struct ModelChoice: Codable, Hashable, Sendable {
    public let provider: ModelProvider
    public let address: String?
    public let apiKey: String?
    public let model: String
    public let contextWindow: Int?

    public init(
        provider: ModelProvider, address: String? = nil, apiKey: String? = nil, model: String, contextWindow: Int? = nil
    ) {
        self.provider = provider
        self.address = address
        self.apiKey = apiKey
        self.model = model
        self.contextWindow = contextWindow
    }
}

/// A bot of a space, as someone in it sees it: whether it's the main one, and its configuration but
/// its key, of which only whether there is one.
public struct SpaceBot: Codable, Hashable, Sendable, Identifiable {
    public let id: BotID
    public let name: String
    public let instructions: String
    public let provider: ModelProvider
    public let address: String?
    public let hasKey: Bool
    public let model: String
    public let contextWindow: Int?
    public let isMain: Bool

    public init(
        id: BotID, name: String, instructions: String, provider: ModelProvider, address: String?, hasKey: Bool,
        model: String, contextWindow: Int?, isMain: Bool
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.provider = provider
        self.address = address
        self.hasKey = hasKey
        self.model = model
        self.contextWindow = contextWindow
        self.isMain = isMain
    }
}

/// The models where a bot's model would run, as asked with what's chosen so far: the model itself
/// isn't needed yet.
public struct ModelsRequest: Codable, Hashable, Sendable {
    public let provider: ModelProvider
    public let address: String?
    public let apiKey: String?
    /// The bot whose saved key is asked with when none is typed, in the space `spaceID`.
    public let botID: BotID?
    public let spaceID: SpaceID?

    public init(
        provider: ModelProvider, address: String? = nil, apiKey: String? = nil, botID: BotID? = nil,
        spaceID: SpaceID? = nil
    ) {
        self.provider = provider
        self.address = address
        self.apiKey = apiKey
        self.botID = botID
        self.spaceID = spaceID
    }
}

/// What a provider was found to offer, asked with what's chosen so far: its models, or why it
/// couldn't be asked.
public enum ModelsAnswer: Codable, Hashable, Sendable {
    case found([String])
    case unavailable(String)
}

/// Who runs a bot's model: Apple's on-device model, an Ollama server, a server that speaks OpenAI's
/// API, or a provider's cloud.
public enum ModelProvider: String, Codable, Hashable, Sendable, CaseIterable {
    case appleSystem = "system"
    case ollama
    case openAICompatible = "openai-compatible"
    case openAI = "openai"
    case anthropic
    case gemini

    /// Where its models run: on this machine, on a server at an address, or in its cloud.
    public enum Kind: Sendable {
        case local
        case server
        case cloud
    }

    public var kind: Kind {
        switch self {
        case .appleSystem: .local
        case .ollama, .openAICompatible: .server
        case .openAI, .anthropic, .gemini: .cloud
        }
    }
}

/// A space called `name` from now on.
public struct RenameSpaceRequest: Codable, Hashable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// A new invite to a space: working for so many days, or until it's used when none are given.
public struct MakeInviteRequest: Codable, Hashable, Sendable {
    public let validForDays: Int?

    public init(validForDays: Int?) {
        self.validForDays = validForDays
    }
}

/// A new invite, once: the link to give one person, and the token in it, which no one keeps.
public struct SpaceInviteOffer: Codable, Hashable, Sendable {
    public let id: String
    public let token: String
    public let link: String
    /// When it stops working: none when it works until it's used.
    public let expiresAt: Date?

    public init(id: String, token: String, link: String, expiresAt: Date?) {
        self.id = id
        self.token = token
        self.link = link
        self.expiresAt = expiresAt
    }
}

/// An invite that still works, as its space's admins see it: never its token.
public struct SpaceInviteListing: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    /// When it stops working: none when it works until it's used.
    public let expiresAt: Date?

    public init(id: String, expiresAt: Date?) {
        self.id = id
        self.expiresAt = expiresAt
    }
}

/// An invite to a space, as its link writes it: `turgai://join/<space>/<token>`.
public struct SpaceInviteLink: Hashable, Sendable, CustomStringConvertible {
    public let spaceID: SpaceID
    public let token: String

    public init(spaceID: SpaceID, token: String) {
        self.spaceID = spaceID
        self.token = token
    }

    /// `written`, a link as it's pasted, its space around it aside: none when it isn't an invite's.
    public init?(_ written: String) {
        let words = written.split(whereSeparator: \.isWhitespace)
        guard words.count == 1, let link = words.first, link.hasPrefix(Self.prefix) else { return nil }
        let parts = link.dropFirst(Self.prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil, !parts[1].isEmpty else { return nil }
        self.init(spaceID: SpaceID(rawValue: String(parts[0])), token: String(parts[1]))
    }

    public var description: String { Self.prefix + "\(spaceID.rawValue)/\(token)" }

    private static let prefix = "turgai://join/"
}

/// Joining a space with the token an invite's link carries.
public struct JoinSpaceRequest: Codable, Hashable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

/// A connection of a space, as whoever configures them sees it: how it's set up, whether it has its
/// secret, whether it's running, and why it stopped last, when it stopped by itself.
public struct SpaceConnection: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let enabled: Bool
    public let platform: ConnectionPlatform
    public let hasToken: Bool
    public let running: Bool
    public let stopped: String?

    public init(
        id: String, label: String, enabled: Bool, platform: ConnectionPlatform, hasToken: Bool, running: Bool,
        stopped: String?
    ) {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.platform = platform
        self.hasToken = hasToken
        self.running = running
        self.stopped = stopped
    }
}

/// The platform a connection is on, with what it's set up with there.
public enum ConnectionPlatform: Codable, Hashable, Sendable {
    /// A Telegram bot, reached by the chats listed: every chat when none are.
    case telegram(chatIDs: [Int64])
}

/// A connection as whoever configures it gives it: a token typed now, which none keeps as it's
/// saved; none keeps the saved one.
public struct ConnectionSettings: Codable, Hashable, Sendable {
    public let label: String
    public let enabled: Bool
    public let platform: ConnectionPlatform
    public let token: String?

    public init(label: String, enabled: Bool, platform: ConnectionPlatform, token: String?) {
        self.label = label
        self.enabled = enabled
        self.platform = platform
        self.token = token
    }
}
