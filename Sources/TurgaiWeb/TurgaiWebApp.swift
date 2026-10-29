import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import ServiceLifecycle
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiPersistence
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct TurgaiWebConfiguration: Sendable {
    public let storage: TurgaiStorageConfiguration?
    public let postgresPassword: String?
    public let complete: Bool

    public var isReady: Bool {
        guard complete, let storage else {
            return false
        }
        if case .postgres = storage {
            return postgresPassword?.trimmed().isEmpty == false
        }
        return true
    }

    public static func load(directory: URL) throws -> Self {
        let stateURL = directory.appendingPathComponent("setup.json")
        let postgresPasswordURL = directory.appendingPathComponent("postgres-password")
        let state =
            try (try? Data(contentsOf: stateURL)).map {
                try JSONDecoder().decode(TurgaiSetupStore.State.self, from: $0)
            } ?? TurgaiSetupStore.State()
        let postgresPassword = try? String(contentsOf: postgresPasswordURL, encoding: .utf8)
        return Self(
            storage: state.storage,
            postgresPassword: postgresPassword,
            complete: state.complete
        )
    }

    private init(
        storage: TurgaiStorageConfiguration?,
        postgresPassword: String?,
        complete: Bool
    ) {
        self.storage = storage
        self.postgresPassword = postgresPassword
        self.complete = complete
    }
}

/// The configured localhost dashboard and application UI.
public struct TurgaiMainWebApp: Sendable {
    static let sessionCookieName = "turgai_auth"
    static let bootstrapChallengeCookieName = "turgai_bootstrap"

    let directory: URL
    let auth: TurgaiAuth
    let setup: TurgaiSetupStore
    let agentProfiles: TurgaiAgentProfileStore
    let agentCredentials: AgentCredentialStore
    let requestLimits: RequestLimitStore
    let channelSecrets: ChannelSecretStore
    let runtimeSnapshots: @Sendable (Membership) async -> [TurgaiAgentRuntimeSnapshot]
    let webChatBridge: TurgaiWebChatBridge
    let apiConfiguration: APIConfiguration

    public init(
        auth: TurgaiAuth,
        directory: URL,
        agentProfiles: TurgaiAgentProfileStore,
        agentCredentials: AgentCredentialStore,
        requestLimits: RequestLimitStore,
        channelSecrets: ChannelSecretStore,
        runtimeSnapshots: @escaping @Sendable (Membership) async -> [TurgaiAgentRuntimeSnapshot] = { _ in [] },
        setup: TurgaiSetupStore,
        webChatBridge: TurgaiWebChatBridge,
        apiConfiguration: APIConfiguration = .init()
    ) throws {
        self.directory = directory
        self.auth = auth
        self.setup = setup
        self.agentProfiles = agentProfiles
        self.agentCredentials = agentCredentials
        self.requestLimits = requestLimits
        self.channelSecrets = channelSecrets
        self.runtimeSnapshots = runtimeSnapshots
        self.webChatBridge = webChatBridge
        self.apiConfiguration = apiConfiguration
    }
}
