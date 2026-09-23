import DistributedCluster
import TurgaiDomain

public struct TurgaiChannelRuntimeDependencies: Sendable {
    public let secrets: ChannelSecretStore
    public let connections: TurgaiConnections
    public let attachments: AttachmentResolver
    public let loadPersistedConversationIDs: @Sendable () async throws -> [ConversationID]

    fileprivate init(
        secrets: ChannelSecretStore,
        connections: TurgaiConnections,
        attachments: AttachmentResolver,
        loadPersistedConversationIDs: @escaping @Sendable () async throws -> [ConversationID]
    ) {
        self.secrets = secrets
        self.connections = connections
        self.attachments = attachments
        self.loadPersistedConversationIDs = loadPersistedConversationIDs
    }
}

public enum TurgaiChannelRuntimeError: Error, Sendable {
    case unavailable
}

/// Supplies node-local application services to an activated Channel actor.
/// Durable channel configuration and provider state remain in the actor's
/// event journal; this plugin only supplies the local clients needed to run it.
public actor TurgaiChannelRuntimePlugin: Plugin {
    public static let pluginKey: Key = "$turgaiChannelRuntime"

    public nonisolated var key: Key { Self.pluginKey }

    private enum Lifecycle {
        case awaitingStart
        case running(TurgaiChannelRuntimeDependencies)
        case stopped
    }

    private let agentProfiles: TurgaiAgentProfileStore
    private let secrets: ChannelSecretStore
    private let attachments: AttachmentResolver
    private let loadPersistedConversationIDs: @Sendable () async throws -> [ConversationID]
    private var lifecycle: Lifecycle = .awaitingStart

    public init(
        agentProfiles: TurgaiAgentProfileStore,
        secrets: ChannelSecretStore,
        attachments: AttachmentResolver,
        loadPersistedConversationIDs: @escaping @Sendable () async throws -> [ConversationID]
    ) {
        self.agentProfiles = agentProfiles
        self.secrets = secrets
        self.attachments = attachments
        self.loadPersistedConversationIDs = loadPersistedConversationIDs
    }

    public func start(_ system: ClusterSystem) async throws {
        lifecycle = .running(
            TurgaiChannelRuntimeDependencies(
                secrets: secrets,
                connections: TurgaiConnections(
                    actorSystem: system,
                    agentProfiles: agentProfiles
                ),
                attachments: attachments,
                loadPersistedConversationIDs: loadPersistedConversationIDs
            )
        )
    }

    public func stop(_ system: ClusterSystem) async {
        lifecycle = .stopped
    }

    public func dependencies() throws -> TurgaiChannelRuntimeDependencies {
        guard case .running(let dependencies) = lifecycle else {
            throw TurgaiChannelRuntimeError.unavailable
        }
        return dependencies
    }
}

extension ClusterSystem {
    public var turgaiChannelRuntime: TurgaiChannelRuntimePlugin {
        let key = TurgaiChannelRuntimePlugin.pluginKey
        guard let plugin = settings.plugins[key] else {
            fatalError("No plugin found for key: [\(key)], installed plugins: \(settings.plugins)")
        }
        return plugin
    }
}
