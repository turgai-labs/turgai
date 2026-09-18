import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import ServiceLifecycle
import TurgaiApplication
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
    public let telegramToken: String?
    public let telegramChatIDs: [Int64]
    public let complete: Bool

    public var isReady: Bool {
        guard complete, let storage else {
            return false
        }
        if case .postgres = storage {
            return postgresPassword?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return true
    }

    public static func load(directory: URL) throws -> Self {
        let stateURL = directory.appendingPathComponent("setup.json")
        let secretURL = directory.appendingPathComponent("telegram-token")
        let postgresPasswordURL = directory.appendingPathComponent("postgres-password")
        let state =
            try (try? Data(contentsOf: stateURL)).map {
                try JSONDecoder().decode(TurgaiSetupStore.State.self, from: $0)
            } ?? TurgaiSetupStore.State()
        let token = try? String(contentsOf: secretURL, encoding: .utf8)
        let postgresPassword = try? String(contentsOf: postgresPasswordURL, encoding: .utf8)
        return Self(
            storage: state.storage,
            postgresPassword: postgresPassword,
            telegramToken: token,
            telegramChatIDs: state.telegramChatIDs,
            complete: state.complete
        )
    }

    private init(
        storage: TurgaiStorageConfiguration?,
        postgresPassword: String?,
        telegramToken: String?,
        telegramChatIDs: [Int64],
        complete: Bool
    ) {
        self.storage = storage
        self.postgresPassword = postgresPassword
        self.telegramToken = telegramToken
        self.telegramChatIDs = telegramChatIDs
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
    let runtimeSnapshots: @Sendable () async -> [TurgaiAgentRuntimeSnapshot]
    let webChatBridge: TurgaiWebChatBridge

    public init(
        auth: TurgaiAuth,
        directory: URL,
        agentProfiles: TurgaiAgentProfileStore,
        runtimeSnapshots: @escaping @Sendable () async -> [TurgaiAgentRuntimeSnapshot] = { [] },
        setup: TurgaiSetupStore,
        webChatBridge: TurgaiWebChatBridge
    ) throws {
        self.directory = directory
        self.auth = auth
        self.setup = setup
        self.agentProfiles = agentProfiles
        self.runtimeSnapshots = runtimeSnapshots
        self.webChatBridge = webChatBridge
    }
}
