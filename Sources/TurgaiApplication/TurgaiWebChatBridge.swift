import DistributedCluster
import Foundation
import Hail
import TurgaiDomain
import TurgaiObjects

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
        let conversations: ConversationStorage
        let channels: ChannelStorage
        let actorSystem: ClusterSystem
    }

    private var runtime: Runtime?

    public init() {}

    public func install(
        _ connections: TurgaiConnections,
        objectCatalog: ObjectCatalog,
        conversations: ConversationStorage,
        channels: ChannelStorage,
        actorSystem: ClusterSystem
    ) {
        self.runtime = Runtime(
            connections: connections,
            objectCatalog: objectCatalog,
            conversations: conversations,
            channels: channels,
            actorSystem: actorSystem
        )
    }

    /// Every conversation there is, in the order they started.
    public func conversationIDs() async throws -> [ConversationID] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.conversations.all()
    }

    /// Every Telegram channel there is, in the order they were made.
    public func channelIDs() async throws -> [UUID] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.channels.ids(TelegramProvider.providerID)
    }

    /// Starts the conversation `conversationID`, unless it's started already.
    public func startConversation(_ conversationID: ConversationID) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        try await runtime.conversations.add(conversationID)
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

    public func conversationHistory(
        for conversationID: ConversationID,
        role: TurgaiAgentRole
    ) async throws -> [ConversationHistoryEntry] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.connections.conversationHistory(
            for: conversationID,
            role: role
        )
    }

    /// The objects `person` may read, as they list them in a conversation: on their behalf, in its
    /// group.
    public func objects(
        listedTo person: TurgaiDomain.UserID,
        in conversationID: ConversationID,
        role: TurgaiAgentRole
    ) async throws -> [ObjectEntry] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let scope = try await runtime.connections.scope(of: person, in: conversationID, role: role)
        return try await CallChain.$current.withValue(.start(scope, in: nil)) { try await runtime.objectCatalog.entries() }
    }

    /// Shares the object made here as `identity` with everyone, as far as `level`, or takes their
    /// access away, on behalf of `person` in a conversation: refused unless they may change it.
    public func share(
        _ identity: ObjectIdentity, withEveryone level: AccessLevel?,
        by person: TurgaiDomain.UserID, in conversationID: ConversationID, role: TurgaiAgentRole
    ) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let scope = try await runtime.connections.scope(of: person, in: conversationID, role: role)
        let object = try await DynamicObject.resolve(on: runtime.actorSystem, identity: identity)
        try await CallChain.$current.withValue(.start(scope, in: nil)) { try await object.share(with: .everyone, level) }
    }

    public func conversationTurns(
        for conversationID: ConversationID,
        role: TurgaiAgentRole,
        askedBy person: TurgaiDomain.UserID
    ) async throws -> [ConversationTurn] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.connections.conversationTurns(for: conversationID, role: role, askedBy: person)
    }

    public func conversationStatus(
        for conversationID: ConversationID,
        role: TurgaiAgentRole
    ) async throws -> ConversationStatus {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.connections.conversationStatus(
            for: conversationID,
            role: role
        )
    }
}

public enum TurgaiWebChatBridgeError: Error, Sendable {
    case runtimeUnavailable
}
