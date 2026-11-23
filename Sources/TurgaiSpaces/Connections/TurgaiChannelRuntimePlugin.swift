import DistributedCluster
import EventSourcing
import TurgaiDomain
import TurgaiObjects
import TurgaiPeople

public struct TurgaiChannelRuntimeDependencies: Sendable {
    public let secrets: ChannelSecretStore
    /// Who's the same human as whom, which `/link` says.
    public let linking: PersonLinking

    fileprivate init(
        secrets: ChannelSecretStore,
        linking: PersonLinking
    ) {
        self.secrets = secrets
        self.linking = linking
    }
}

public enum TurgaiChannelRuntimeError: Error, Sendable {
    case unavailable
}

/// The stores a connection's run reads on this node: its secrets, and who's linked to whom.
/// Nothing of a connection runs here: its space starts its run, which runs its own platform.
public actor TurgaiChannelRuntimePlugin: Plugin {
    public static let pluginKey: Key = "$turgaiChannelRuntime"

    public nonisolated var key: Key { Self.pluginKey }

    private enum Lifecycle {
        case awaitingStart
        case running(TurgaiChannelRuntimeDependencies)
        case stopped
    }

    private let secrets: ChannelSecretStore
    private let linking: PersonLinking
    private var lifecycle: Lifecycle = .awaitingStart

    public init(
        secrets: ChannelSecretStore,
        linking: PersonLinking
    ) {
        self.secrets = secrets
        self.linking = linking
    }

    public func start(_ system: ClusterSystem) async throws {
        lifecycle = .running(
            TurgaiChannelRuntimeDependencies(
                secrets: secrets,
                linking: linking
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
