import DistributedCluster
import Elementary
import EventSourcing
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import ServiceLifecycle
import TurgaiAgents
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiObjects
import TurgaiPeople
import TurgaiPersistence
import TurgaiSpaces
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct TurgaiWebConfiguration: Sendable {
    public let storage: TurgaiStorageConfiguration?
    public let complete: Bool

    public var isReady: Bool {
        complete && storage != nil
    }

    public static func load(directory: URL) throws -> Self {
        let stateURL = directory.appendingPathComponent("setup.json")
        let state =
            try (try? Data(contentsOf: stateURL)).map {
                try JSONDecoder().decode(TurgaiSetupStore.State.self, from: $0)
            } ?? TurgaiSetupStore.State()
        return Self(storage: state.storage, complete: state.complete)
    }

    private init(storage: TurgaiStorageConfiguration?, complete: Bool) {
        self.storage = storage
        self.complete = complete
    }
}

/// The configured localhost dashboard and application UI: built once Turgai's cluster runs, on it.
public struct TurgaiMainWebApp: Sendable {
    static let sessionCookieName = "turgai_auth"
    static let bootstrapChallengeCookieName = "turgai_bootstrap"

    let directory: URL
    let auth: TurgaiAuth
    let setup: TurgaiSetupStore
    let agentCredentials: AgentCredentialStore
    let requestLimits: RequestLimitStore
    let channelSecrets: ChannelSecretStore
    let system: ClusterSystem
    /// Where the agents keep what they did, read for their past turns.
    let journal: any EventStore
    /// Who's the same human as whom.
    let linking: PersonLinking
    let apiConfiguration: APIConfiguration

    public init(
        auth: TurgaiAuth,
        directory: URL,
        agentCredentials: AgentCredentialStore,
        requestLimits: RequestLimitStore,
        channelSecrets: ChannelSecretStore,
        setup: TurgaiSetupStore,
        system: ClusterSystem,
        journal: any EventStore,
        linking: PersonLinking,
        apiConfiguration: APIConfiguration = .init()
    ) throws {
        self.directory = directory
        self.auth = auth
        self.setup = setup
        self.agentCredentials = agentCredentials
        self.requestLimits = requestLimits
        self.channelSecrets = channelSecrets
        self.system = system
        self.journal = journal
        self.linking = linking
        self.apiConfiguration = apiConfiguration
    }
}
