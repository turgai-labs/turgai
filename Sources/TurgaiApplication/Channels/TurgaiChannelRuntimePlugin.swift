import DistributedCluster
import EventSourcing
import TurgaiAgents
import TurgaiDomain
import TurgaiObjects
import TurgaiPeople

public struct TurgaiChannelRuntimeDependencies: Sendable {
    public let secrets: ChannelSecretStore
    /// Who's the same human as whom, which `/link` says.
    public let linking: PersonLinking
    /// Each running Telegram bot's files, by the channel its chats are in.
    public let telegramFiles: TelegramFiles
    /// The node's models, as agents' profiles name them.
    public let endpoints: AgentModelEndpointFactory

    fileprivate init(
        secrets: ChannelSecretStore,
        linking: PersonLinking,
        telegramFiles: TelegramFiles,
        endpoints: AgentModelEndpointFactory
    ) {
        self.secrets = secrets
        self.linking = linking
        self.telegramFiles = telegramFiles
        self.endpoints = endpoints
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

    private let secrets: ChannelSecretStore
    private let telegramFiles: TelegramFiles
    private let endpoints: AgentModelEndpointFactory
    private let linking: PersonLinking
    private var lifecycle: Lifecycle = .awaitingStart

    public init(
        secrets: ChannelSecretStore,
        telegramFiles: TelegramFiles,
        endpoints: AgentModelEndpointFactory,
        linking: PersonLinking
    ) {
        self.secrets = secrets
        self.telegramFiles = telegramFiles
        self.endpoints = endpoints
        self.linking = linking
    }

    public func start(_ system: ClusterSystem) async throws {
        lifecycle = .running(
            TurgaiChannelRuntimeDependencies(
                secrets: secrets,
                linking: linking,
                telegramFiles: telegramFiles,
                endpoints: endpoints
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
