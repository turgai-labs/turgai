import Hail
import SQLiteNIO
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum AgentProfileStorageError: Error, Equatable, Sendable {
    /// A kept profile that isn't one this build can run.
    case invalidProfile
}

/// Where the agent profiles are kept: each found by its id, and one of them the default, which
/// exists while it's the default. The first profile kept becomes the default, in the same write.
public struct AgentProfileStorage: Sendable {
    /// Every profile, by name.
    public var all: @Sendable () async throws -> [TurgaiAgentProfile]
    public var withID: @Sendable (_ id: String) async throws -> TurgaiAgentProfile?
    /// The profile that answers when none is named, once there is one.
    public var defaultProfile: @Sendable () async throws -> TurgaiAgentProfile?
    public var ids: @Sendable () async throws -> Set<String>
    /// Keeps a new profile: the first one becomes the default.
    public var insert: @Sendable (TurgaiAgentProfile) async throws -> Void
    /// Changes the profile with the profile's id to it: whether there was one.
    public var update: @Sendable (TurgaiAgentProfile) async throws -> Bool
    /// Makes the profile `id`, which exists, the default.
    public var setDefault: @Sendable (_ id: String) async throws -> Void
    /// Deletes the profile `id`, which isn't the default: whether there was one.
    public var delete: @Sendable (_ id: String) async throws -> Bool

    public init(
        all: @escaping @Sendable () async throws -> [TurgaiAgentProfile],
        withID: @escaping @Sendable (_ id: String) async throws -> TurgaiAgentProfile?,
        defaultProfile: @escaping @Sendable () async throws -> TurgaiAgentProfile?,
        ids: @escaping @Sendable () async throws -> Set<String>,
        insert: @escaping @Sendable (TurgaiAgentProfile) async throws -> Void,
        update: @escaping @Sendable (TurgaiAgentProfile) async throws -> Bool,
        setDefault: @escaping @Sendable (_ id: String) async throws -> Void,
        delete: @escaping @Sendable (_ id: String) async throws -> Bool
    ) {
        self.all = all
        self.withID = withID
        self.defaultProfile = defaultProfile
        self.ids = ids
        self.insert = insert
        self.update = update
        self.setDefault = setDefault
        self.delete = delete
    }

    /// The agent profiles in Turgai's database, their tables made if they aren't there yet.
    public static func live(in persistence: TurgaiPersistence) async throws -> Self {
        let table = try await AgentProfileTable(in: persistence)
        return Self(
            all: { try await table.all() },
            withID: { try await table.profile(id: $0) },
            defaultProfile: { try await table.defaultProfile() },
            ids: { try await table.ids() },
            insert: { try await table.insert($0) },
            update: { try await table.update($0) },
            setDefault: { try await table.setDefault(id: $0) },
            delete: { try await table.delete(id: $0) }
        )
    }

    /// Agent profiles kept in memory, a new place each time, the first one the default.
    public static var test: Self {
        let profiles = MemoryAgentProfiles()
        return Self(
            all: { await profiles.all() },
            withID: { await profiles.withID($0) },
            defaultProfile: { await profiles.defaultProfile() },
            ids: { await profiles.ids() },
            insert: { await profiles.insert($0) },
            update: { await profiles.update($0) },
            setDefault: { await profiles.setDefault($0) },
            delete: { await profiles.delete($0) }
        )
    }
}

/// The agent profiles in Turgai's database, each setting in a column of its own: its provider's
/// settings checked to be exactly that provider's.
private struct AgentProfileTable: Sendable {
    // Held, not only its connection: the connection stays open while the table is used.
    private let persistence: TurgaiPersistence
    private var connection: SQLiteConnection { persistence.connection }

    /// The tables in `persistence`, made if they aren't there yet.
    init(in persistence: TurgaiPersistence) async throws {
        self.persistence = persistence
        for statement in [
            """
            CREATE TABLE IF NOT EXISTS agent_profiles (
                id               TEXT    NOT NULL PRIMARY KEY,
                name             TEXT    NOT NULL,
                model_id         TEXT    NOT NULL,
                reasoning_effort TEXT,
                persona          TEXT,
                instructions     TEXT    NOT NULL,
                availability     TEXT    NOT NULL CHECK (availability IN ('enabled', 'disabled')),
                provider         TEXT    NOT NULL,
                address          TEXT,
                credential       TEXT,
                api              TEXT    CHECK (api IN ('chatCompletions', 'responses')),
                -- Who decides the model's window: you, or the provider, saying it or not.
                context          TEXT    CHECK (context IN ('chosen', 'said', 'unsaid')),
                context_window   INTEGER CHECK (context_window > 0),
                model_path       TEXT,
                gpu_layers       INTEGER,
                created_at       TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                -- The window is there exactly when it's known.
                CHECK ((context_window IS NULL) = (context IS NULL OR context = 'unsaid')),
                CHECK (
                    -- On this machine: Apple's model, its window its own; or a GGUF file, its
                    -- window chosen.
                    (provider = 'system' AND address IS NULL AND credential IS NULL AND api IS NULL
                        AND context IS NULL AND model_path IS NULL AND gpu_layers IS NULL)
                    OR (provider = 'llama-cpp' AND model_path IS NOT NULL AND gpu_layers IS NOT NULL
                        AND context = 'chosen' AND address IS NULL AND credential IS NULL AND api IS NULL)
                    -- A server at an address, its key a choice: Ollama's of your own gives the
                    -- window chosen; Ollama's cloud and a compatible server run the model with
                    -- theirs.
                    OR (provider = 'ollama' AND address IS NOT NULL AND context IS NOT NULL
                        AND api IS NULL AND model_path IS NULL AND gpu_layers IS NULL)
                    OR (provider = 'openai-compatible' AND address IS NOT NULL AND api IS NOT NULL
                        AND context IN ('said', 'unsaid') AND model_path IS NULL AND gpu_layers IS NULL)
                    -- A provider's cloud, at its own address, with a key, and its own window.
                    OR (provider IN ('openai', 'anthropic', 'gemini') AND credential IS NOT NULL
                        AND context IN ('said', 'unsaid')
                        AND address IS NULL AND api IS NULL AND model_path IS NULL AND gpu_layers IS NULL)
                )
            ) WITHOUT ROWID
            """,
            // The profile that answers when none is named: one at most, and one that exists.
            """
            CREATE TABLE IF NOT EXISTS default_agent_profile (
                one        INTEGER NOT NULL PRIMARY KEY CHECK (one = 1),
                profile_id TEXT    NOT NULL REFERENCES agent_profiles (id) ON DELETE RESTRICT
            )
            """,
            // The first profile made is the default, in the same write that makes it.
            """
            CREATE TRIGGER IF NOT EXISTS first_agent_profile_is_default
            AFTER INSERT ON agent_profiles
            WHEN NOT EXISTS (SELECT 1 FROM default_agent_profile)
            BEGIN
                INSERT INTO default_agent_profile (one, profile_id) VALUES (1, NEW.id);
            END
            """,
        ] {
            _ = try await connection.query(statement)
        }
    }

    private static let columns = """
        id, name, model_id, reasoning_effort, persona, instructions, availability,
        provider, address, credential, api, context, context_window, model_path, gpu_layers
        """

    func all() async throws -> [TurgaiAgentProfile] {
        try await connection.query("SELECT \(Self.columns) FROM agent_profiles ORDER BY name COLLATE NOCASE, id")
            .map(Self.profile(from:))
    }

    func profile(id: String) async throws -> TurgaiAgentProfile? {
        try await connection.query("SELECT \(Self.columns) FROM agent_profiles WHERE id = ?", [.text(id)])
            .first.map(Self.profile(from:))
    }

    func defaultProfile() async throws -> TurgaiAgentProfile? {
        try await connection.query(
            """
            SELECT \(Self.columns) FROM agent_profiles
            WHERE id = (SELECT profile_id FROM default_agent_profile WHERE one = 1)
            """
        ).first.map(Self.profile(from:))
    }

    func ids() async throws -> Set<String> {
        Set(try await connection.query("SELECT id FROM agent_profiles").compactMap { $0.column("id")?.string })
    }

    func insert(_ profile: TurgaiAgentProfile) async throws {
        _ = try await connection.query(
            "INSERT INTO agent_profiles (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            Self.binds(of: profile))
    }

    func update(_ profile: TurgaiAgentProfile) async throws -> Bool {
        try await !connection.query(
            """
            UPDATE agent_profiles SET
                name = ?2, model_id = ?3, reasoning_effort = ?4, persona = ?5, instructions = ?6,
                availability = ?7, provider = ?8, address = ?9, credential = ?10, api = ?11,
                context = ?12, context_window = ?13, model_path = ?14, gpu_layers = ?15
            WHERE id = ?1
            RETURNING id
            """,
            Self.binds(of: profile)
        ).isEmpty
    }

    func setDefault(id: String) async throws {
        _ = try await connection.query(
            """
            INSERT INTO default_agent_profile (one, profile_id) VALUES (1, ?)
            ON CONFLICT (one) DO UPDATE SET profile_id = excluded.profile_id
            """,
            [.text(id)])
    }

    func delete(id: String) async throws -> Bool {
        try await !connection.query("DELETE FROM agent_profiles WHERE id = ? RETURNING id", [.text(id)]).isEmpty
    }

    private static func binds(of profile: TurgaiAgentProfile) -> [SQLiteData] {
        func text(_ value: String?) -> SQLiteData { value.map(SQLiteData.text) ?? .null }
        func integer(_ value: Int?) -> SQLiteData { value.map { .integer(SQLiteInt64($0)) } ?? .null }
        var (address, credential, api, context, modelPath, gpuLayers):
            (
                ServerAddress?, AgentCredentialReference?, OpenAICompatibleAPI?, ModelContext?, String?, Int?
            ) = (nil, nil, nil, nil, nil, nil)
        switch profile.providerConfiguration {
        case .local(.appleSystem):
            break
        #if Llama
            case .local(.llamaCPP(let file, let layers, let size)):
                (modelPath, gpuLayers, context) = (file, Int(layers), .chosen(size))
        #endif
        case .server(let server):
            (address, credential, context) = (server.address, server.key, server.context)
            if case .openAICompatible(let kind) = server.software { api = kind }
        case .cloud(let account):
            (credential, context) = (account.key, .providers(account.window))
        }
        let kind: String? =
            switch context {
            case nil: nil
            case .chosen?: "chosen"
            case .providers(.said)?: "said"
            case .providers(.unsaid)?: "unsaid"
            }
        return [
            .text(profile.id), .text(profile.name), .text(profile.model.id.rawValue),
            text(profile.reasoningEffort?.rawValue), text(profile.persona), .text(profile.instructions),
            .text(profile.availability.rawValue), .text(profile.providerConfiguration.provider.name),
            text(address?.description), text(credential?.rawValue), text(api?.rawValue), text(kind),
            integer(context?.window?.tokens),
            text(modelPath), integer(gpuLayers),
        ]
    }

    private static func profile(from row: SQLiteRow) throws -> TurgaiAgentProfile {
        func text(_ column: String) -> String? { row.column(column)?.string }
        func integer(_ column: String) -> Int? { row.column(column)?.integer.map { Int($0) } }
        guard let id = text("id"), let name = text("name"), let modelID = text("model_id"),
            let instructions = text("instructions"),
            let availability = text("availability").flatMap(AgentAvailability.init(rawValue:)),
            let provider = text("provider").flatMap(AgentProvider.init(name:))
        else { throw AgentProfileStorageError.invalidProfile }
        let credential = text("credential").map(AgentCredentialReference.init(rawValue:))
        func window() throws -> ContextWindow {
            guard let tokens = integer("context_window") else { throw AgentProfileStorageError.invalidProfile }
            return try ContextWindow(tokens: tokens)
        }
        /// The window the provider runs the model with.
        func providerWindow() throws -> ProviderWindow {
            switch text("context") {
            case "said": .said(try window())
            case "unsaid": .unsaid
            default: throw AgentProfileStorageError.invalidProfile
            }
        }
        /// How much context a server's model gets.
        func context() throws -> ModelContext {
            text("context") == "chosen" ? .chosen(try window()) : .providers(try providerWindow())
        }
        func address() throws -> ServerAddress {
            guard let written = text("address") else { throw AgentProfileStorageError.invalidProfile }
            return try ServerAddress(written)
        }
        func key() throws -> AgentCredentialReference {
            guard let credential else { throw AgentProfileStorageError.invalidProfile }
            return credential
        }
        let configuration: AgentProviderConfiguration
        switch provider {
        case .appleSystem:
            configuration = .local(.appleSystem)
        #if Llama
            case .llamaCPP:
                guard let path = text("model_path"), let layers = integer("gpu_layers") else {
                    throw AgentProfileStorageError.invalidProfile
                }
                configuration = .local(.llamaCPP(file: path, gpuLayers: Int32(layers), contextWindow: try window()))
        #endif
        case .ollama:
            configuration = .server(
                ModelServer(software: .ollama, address: try address(), key: credential, context: try context()))
        case .openAICompatible:
            guard let api = text("api").flatMap(OpenAICompatibleAPI.init(rawValue:)) else {
                throw AgentProfileStorageError.invalidProfile
            }
            configuration = .server(
                ModelServer(
                    software: .openAICompatible(api), address: try address(), key: credential,
                    context: .providers(try providerWindow())))
        case .openAI:
            configuration = .cloud(CloudAccount(provider: .openAI, key: try key(), window: try providerWindow()))
        case .anthropic:
            configuration = .cloud(CloudAccount(provider: .anthropic, key: try key(), window: try providerWindow()))
        case .gemini:
            configuration = .cloud(CloudAccount(provider: .gemini, key: try key(), window: try providerWindow()))
        }
        return try TurgaiAgentProfile(
            id: id,
            name: name,
            providerConfiguration: configuration,
            modelID: AgentModelID(rawValue: modelID),
            reasoningEffort: try text("reasoning_effort").map { try ReasoningEffort($0) },
            persona: text("persona"),
            instructions: instructions,
            availability: availability
        )
    }
}

/// The profiles of ``AgentProfileStorage/test``.
private actor MemoryAgentProfiles {
    private var profiles: [String: TurgaiAgentProfile] = [:]
    private var defaultID: String?

    func all() -> [TurgaiAgentProfile] {
        profiles.values.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    func withID(_ id: String) -> TurgaiAgentProfile? {
        profiles[id]
    }

    func defaultProfile() -> TurgaiAgentProfile? {
        defaultID.flatMap { profiles[$0] }
    }

    func ids() -> Set<String> {
        Set(profiles.keys)
    }

    func insert(_ profile: TurgaiAgentProfile) {
        profiles[profile.id] = profile
        if defaultID == nil { defaultID = profile.id }
    }

    func update(_ profile: TurgaiAgentProfile) -> Bool {
        guard profiles[profile.id] != nil else { return false }
        profiles[profile.id] = profile
        return true
    }

    func setDefault(_ id: String) {
        defaultID = id
    }

    func delete(_ id: String) -> Bool {
        profiles.removeValue(forKey: id) != nil
    }
}
