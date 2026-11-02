import DistributedCluster
import Foundation
import Hail
import TurgaiCalls
import TurgaiDomain
import TurgaiObjects
import TurgaiSpaces

public struct WebSessionID: Hashable, Sendable, Codable, Identifiable {
    public let rawValue: UUID

    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Gives the web application access to the live conversation connections
/// after the application runtime has finished booting.
public actor TurgaiWebChatBridge {
    private struct Runtime {
        let connections: TurgaiConnections
        let objectCatalog: ObjectCatalog
        let channels: ChannelStorage
        let actorSystem: ClusterSystem
        /// Turgai's own space.
        let turgaiSpace: SpaceID
    }

    private var runtime: Runtime?

    public init() {}

    public func install(
        _ connections: TurgaiConnections,
        objectCatalog: ObjectCatalog,
        channels: ChannelStorage,
        actorSystem: ClusterSystem,
        turgaiSpace: SpaceID
    ) {
        self.runtime = Runtime(
            connections: connections,
            objectCatalog: objectCatalog,
            channels: channels,
            actorSystem: actorSystem,
            turgaiSpace: turgaiSpace
        )
    }

    /// Turgai's own space following `accounts`: called Turgai, with each account that can sign in
    /// in it, an administrator as its admin. Before the runtime runs there's no space to tell: it's
    /// told every account as it starts.
    public func follow(_ accounts: [Account]) async throws {
        guard let runtime else { return }
        let inIt = accounts.filter { $0.status != .disabled }.map { account -> (TurgaiDomain.UserID, SpaceRole) in
            (.account(account.id), account.role == .administrator ? .admin : .member)
        }
        try await Space.resolve(on: runtime.actorSystem, id: runtime.turgaiSpace)
            .follow(accounts: Dictionary(uniqueKeysWithValues: inIt), named: Self.turgaisName)
    }

    /// What Turgai's own space is called.
    private static let turgaisName = SpaceName("Turgai")!

    /// `guest` in Turgai's own space, as a member: where their conversations are.
    public func admit(guest: TurgaiDomain.UserID) async throws {
        guard let runtime else { throw TurgaiWebChatBridgeError.runtimeUnavailable }
        try await Space.resolve(on: runtime.actorSystem, id: runtime.turgaiSpace).admit(guest)
    }

    /// What a person does with spaces, once the runtime runs.
    public func spaces() throws -> Spaces {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return Spaces(actorSystem: runtime.actorSystem)
    }

    /// Every Telegram channel there is, in the order they were made.
    public func channelIDs() async throws -> [UUID] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.channels.ids(TelegramProvider.providerID)
    }

    /// Starts the conversation `conversationID` in `space`, or else Turgai's own, answered by
    /// `agent`, with `person` the first of its people: refused unless they're in that space.
    public func startConversation(
        _ conversationID: ConversationID, in space: SpaceID?, agent: AgentProfileID, by person: TurgaiDomain.UserID
    ) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        try await Conversation.resolve(on: runtime.actorSystem, conversationID: conversationID)
            .start(in: space ?? runtime.turgaiSpace, agent: agent, by: person)
    }

    /// The conversations `person` is in, the one something was last said in first, as the
    /// conversation directory has them: a moment behind the conversations.
    public func conversations(of person: TurgaiDomain.UserID) async throws -> [ConversationListing] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.actorSystem.singleton
            .proxy(ConversationDirectory.self, name: ConversationDirectory.singletonName)
            .conversations(of: person)
    }

    /// `person` leaving the conversation `conversationID`: refused unless they're in it.
    public func leave(_ conversationID: ConversationID, as person: TurgaiDomain.UserID) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        try await Conversation.resolve(on: runtime.actorSystem, conversationID: conversationID).leave(person)
    }

    /// The conversation `conversationID` called `title`, as `person` titles it: refused unless
    /// they're in it.
    public func title(
        _ conversationID: ConversationID, _ title: ConversationTitle, by person: TurgaiDomain.UserID
    ) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        try await Conversation.resolve(on: runtime.actorSystem, conversationID: conversationID).title(title, by: person)
    }

    /// The conversation `conversationID`, as `person` reads it: refused unless they're one of its
    /// people.
    public func conversation(
        _ conversationID: ConversationID, readBy person: TurgaiDomain.UserID
    ) async throws -> ConversationOutline {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await Conversation.resolve(on: runtime.actorSystem, conversationID: conversationID)
            .reading(by: person)
    }

    public func openSession(id: WebSessionID) async throws -> TurgaiConnections.WebSession {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return await runtime.connections.addWebSession(id: id)
    }

    public func configureChannel(_ configuration: ChannelConfiguration<TelegramProvider>) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let channel = try await TelegramChannel.resolve(
            on: runtime.actorSystem,
            configuration: configuration
        )
        try await channel.replaceConfiguration(configuration)
        try await runtime.channels.add(configuration.id, TelegramProvider.providerID)
    }

    public func channelState(
        for configuration: ChannelConfiguration<TelegramProvider>
    ) async throws -> ChannelState<TelegramProvider> {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let channel = try await TelegramChannel.resolve(
            on: runtime.actorSystem,
            configuration: configuration
        )
        return try await channel.currentState()
    }

    public func channelState(for channelID: UUID) async throws -> ChannelState<TelegramProvider> {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let channel = try await TelegramChannel.resolve(
            on: runtime.actorSystem,
            channelID: channelID
        )
        return try await channel.currentState()
    }

    public func deleteChannel(_ configuration: ChannelConfiguration<TelegramProvider>) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let channel = try await TelegramChannel.resolve(
            on: runtime.actorSystem,
            configuration: configuration
        )
        try await channel.delete()
        try await runtime.channels.remove(configuration.id)
    }

    public func deleteChannel(id: UUID) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let channel = try await TelegramChannel.resolve(
            on: runtime.actorSystem,
            channelID: id
        )
        try await channel.delete()
        try await runtime.channels.remove(id)
    }

    /// What's been said in a conversation, as `person` reads it: refused unless they're in it.
    public func conversationHistory(
        of conversationID: ConversationID, for person: TurgaiDomain.UserID
    ) async throws -> [ConversationHistoryEntry] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.connections.history(of: conversationID, for: person)
    }

    /// The objects `person` may read, as they list them in Turgai's own space: on their behalf.
    public func objects(listedTo person: TurgaiDomain.UserID) async throws -> [ObjectEntry] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let scope = try await Space.resolve(on: runtime.actorSystem, id: runtime.turgaiSpace).scope(of: person)
        return try await CallChain.$current.withValue(.start(scope, in: nil)) { try await runtime.objectCatalog.entries() }
    }

    /// Shares the object made here as `identity` with everyone, as far as `level`, or takes their
    /// access away, on behalf of `person` in Turgai's own space: refused unless they may change it.
    public func share(
        _ identity: ObjectIdentity, withEveryone level: AccessLevel?, by person: TurgaiDomain.UserID
    ) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let scope = try await Space.resolve(on: runtime.actorSystem, id: runtime.turgaiSpace).scope(of: person)
        let object = try await DynamicObject.resolve(on: runtime.actorSystem, identity: identity)
        try await CallChain.$current.withValue(.start(scope, in: nil)) { try await object.share(with: .everyone, level) }
    }

    /// The agent's past turns in a conversation, step by step, as `person` asks for them.
    public func conversationTurns(
        of conversationID: ConversationID, askedBy person: TurgaiDomain.UserID
    ) async throws -> [ConversationTurn] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.connections.turns(of: conversationID, askedBy: person)
    }

    /// Whether a conversation's agent is answering, as `person` sees it: refused unless they're in it.
    public func conversationStatus(
        of conversationID: ConversationID, for person: TurgaiDomain.UserID
    ) async throws -> ConversationStatus {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.connections.status(
            of: conversationID,
            for: person
        )
    }
}

public enum TurgaiWebChatBridgeError: Error, Sendable {
    case runtimeUnavailable
}
