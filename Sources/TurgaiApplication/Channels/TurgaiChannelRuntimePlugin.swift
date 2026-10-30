import DistributedCluster
import TurgaiDomain
import TurgaiObjects

public struct TurgaiChannelRuntimeDependencies: Sendable {
    public let secrets: ChannelSecretStore
    public let connections: TurgaiConnections
    /// Each running Telegram bot's files, by the channel its chats are in.
    public let telegramFiles: TelegramFiles
    public let objectCatalog: ObjectCatalog
    /// The node's models, as agents' profiles name them.
    public let endpoints: AgentModelEndpointFactory
    /// The conversations there are.
    public let conversations: ConversationStorage

    fileprivate init(
        secrets: ChannelSecretStore,
        connections: TurgaiConnections,
        telegramFiles: TelegramFiles,
        objectCatalog: ObjectCatalog,
        endpoints: AgentModelEndpointFactory,
        conversations: ConversationStorage
    ) {
        self.secrets = secrets
        self.connections = connections
        self.telegramFiles = telegramFiles
        self.objectCatalog = objectCatalog
        self.endpoints = endpoints
        self.conversations = conversations
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
    private let telegramFiles: TelegramFiles
    private let endpoints: AgentModelEndpointFactory
    private let conversations: ConversationStorage
    private var lifecycle: Lifecycle = .awaitingStart

    public init(
        agentProfiles: TurgaiAgentProfileStore,
        secrets: ChannelSecretStore,
        telegramFiles: TelegramFiles,
        endpoints: AgentModelEndpointFactory,
        conversations: ConversationStorage
    ) {
        self.agentProfiles = agentProfiles
        self.secrets = secrets
        self.telegramFiles = telegramFiles
        self.endpoints = endpoints
        self.conversations = conversations
    }

    public func start(_ system: ClusterSystem) async throws {
        lifecycle = .running(
            TurgaiChannelRuntimeDependencies(
                secrets: secrets,
                connections: TurgaiConnections(
                    actorSystem: system,
                    agentProfiles: agentProfiles,
                    conversations: conversations
                ),
                telegramFiles: telegramFiles,
                objectCatalog: await ObjectCatalog(actorSystem: system),
                endpoints: endpoints,
                conversations: conversations
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

    /// The runtime's plugin, when it's installed: a node without it, such as a test's, has none.
    public var installedTurgaiChannelRuntime: TurgaiChannelRuntimePlugin? {
        settings.plugins[TurgaiChannelRuntimePlugin.pluginKey]
    }
}
