import Hail
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Persistent configuration for one user-facing Turgai agent.
///
/// The identifier is also used as Hail's `Role`, which means a conversation
/// routed to this profile gets the profile's model and transcript identity.
/// Keeping the identifier stable is important: changing a display name or a
/// model must not silently create a new conversation history.
public enum AgentAvailability: String, Codable, Sendable, Equatable {
    case enabled
    case disabled
}

/// Provider-owned configuration for a profile.
public enum AgentProviderConfiguration: Codable, Sendable, Equatable {
    case ollama(baseURL: URL)
    case none

    private enum CodingKeys: String, CodingKey { case kind, baseURL }
    private enum Kind: String, Codable { case ollama, none }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .ollama:
            self = .ollama(baseURL: try values.decode(URL.self, forKey: .baseURL))
        case .none:
            self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ollama(let baseURL):
            try values.encode(Kind.ollama, forKey: .kind)
            try values.encode(baseURL, forKey: .baseURL)
        case .none:
            try values.encode(Kind.none, forKey: .kind)
        }
    }
}

public struct TurgaiAgentProfile: Codable, Equatable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id, name, model, reasoningEffort, providerConfiguration, contextWindow, persona, instructions,
            availability
    }

    public let id: String
    public var name: String
    public var model: AgentModel
    /// Optional provider-facing reasoning effort. Nil delegates the choice to
    /// the selected model provider.
    public var reasoningEffort: ReasoningEffort?
    public var providerConfiguration: AgentProviderConfiguration
    public var contextWindow: Int
    /// Optional persona supplied by configuration. Nil or an empty string
    /// means that no persona instructions are added.
    public var persona: String?
    public var instructions: String
    public var availability: AgentAvailability

    public init(
        id: String,
        name: String,
        model: AgentModel,
        reasoningEffort: ReasoningEffort? = nil,
        providerConfiguration: AgentProviderConfiguration,
        contextWindow: Int = 16_384,
        persona: String? = nil,
        instructions: String = "",
        availability: AgentAvailability = .enabled
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.providerConfiguration = providerConfiguration
        self.contextWindow = contextWindow
        self.persona = persona
        self.instructions = instructions
        self.availability = availability
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        model = try values.decode(AgentModel.self, forKey: .model)
        reasoningEffort = try values.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        providerConfiguration = try values.decode(AgentProviderConfiguration.self, forKey: .providerConfiguration)
        contextWindow = try values.decode(Int.self, forKey: .contextWindow)
        persona = try values.decodeIfPresent(String.self, forKey: .persona)
        instructions = try values.decode(String.self, forKey: .instructions)
        availability = try values.decode(AgentAvailability.self, forKey: .availability)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(model, forKey: .model)
        try values.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try values.encode(providerConfiguration, forKey: .providerConfiguration)
        try values.encode(contextWindow, forKey: .contextWindow)
        try values.encodeIfPresent(persona, forKey: .persona)
        try values.encode(instructions, forKey: .instructions)
        try values.encode(availability, forKey: .availability)
    }
}

public enum TurgaiAgentProfileError: Error, Equatable, Sendable {
    case invalidID(String)
    case invalidName
    case invalidEndpointURL(String)
    case invalidContextWindow(Int)
    case unknownProfile(String)
    case cannotDeleteDefaultProfile
    case noEnabledProfile
}

/// Durable catalog of user-facing agent definitions and the application
/// default. Channel-specific routing belongs to the channel aggregate.
///
/// The catalog is intentionally a small local file rather than a distributed
/// actor. It is application configuration, and all writes are atomic. Reads
/// are actor-isolated so the dashboard and the runtime can share one value
/// without an unchecked sendability escape hatch.
public actor TurgaiAgentProfileStore {
    public static let defaultProfileID = "conversation"
    public static let defaultContextWindow = 16_384

    private struct State: Codable, Sendable {
        var defaultProfileID: String = TurgaiAgentProfileStore.defaultProfileID
        var profiles: [TurgaiAgentProfile] = []
    }

    private static let statePath = "agents/profiles.json"

    private let files: FileClient
    private var state: State

    public init(files: FileClient) throws {
        self.files = files
        var initialState: State = try files.loadDocument(at: Self.statePath) ?? State()
        var shouldPersist = false
        if !initialState.profiles.isEmpty,
            !initialState.profiles.contains(where: { $0.id == initialState.defaultProfileID })
        {
            // A hand-edited file may predate the explicit default ID. Keep
            // startup deterministic while leaving an empty catalog empty.
            initialState.defaultProfileID = initialState.profiles[0].id
            shouldPersist = true
        }
        let canonicalProfiles = initialState.profiles.map { profile in
            var canonical = profile
            if canonical.id == initialState.defaultProfileID, canonical.name == "Conversation" {
                canonical.name = "Turgai"
                shouldPersist = true
            }
            return canonical
        }
        if canonicalProfiles != initialState.profiles {
            initialState.profiles = canonicalProfiles
            shouldPersist = true
        }
        try Self.validateState(initialState)
        self.state = initialState
        if shouldPersist {
            try files.saveDocument(initialState, at: Self.statePath)
        }
    }

    public func profiles() -> [TurgaiAgentProfile] {
        state.profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func profile(id: String) -> TurgaiAgentProfile? {
        state.profiles.first { $0.id == id }
    }

    public func defaultProfile() -> TurgaiAgentProfile? {
        state.profiles.first { $0.id == state.defaultProfileID }
    }

    public func isDefaultProfile(id: String) -> Bool {
        state.defaultProfileID == id
    }

    public func setDefaultProfile(id: String) throws {
        guard let profile = state.profiles.first(where: { $0.id == id }) else {
            throw TurgaiAgentProfileError.unknownProfile(id)
        }
        guard case .enabled = profile.availability else {
            throw TurgaiAgentProfileError.invalidName
        }
        state.defaultProfileID = id
        try persist()
    }

    /// Resolves the configured default agent. Channel-specific routing is
    /// owned by the channel actor and never inferred from this catalog.
    public func defaultProfileID() throws -> String {
        guard let profile = defaultProfile(), profile.availability == .enabled else {
            throw TurgaiAgentProfileError.noEnabledProfile
        }
        return profile.id
    }

    public func update(_ profile: TurgaiAgentProfile) throws {
        guard let index = state.profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw TurgaiAgentProfileError.unknownProfile(profile.id)
        }
        try Self.validate(profile)
        if profile.id == state.defaultProfileID, case .disabled = profile.availability {
            throw TurgaiAgentProfileError.invalidName
        }
        state.profiles[index] = profile
        try persist()
    }

    @discardableResult
    public func create(
        name: String,
        model: AgentModel,
        reasoningEffort: ReasoningEffort? = nil,
        providerConfiguration: AgentProviderConfiguration,
        contextWindow: Int = TurgaiAgentProfileStore.defaultContextWindow,
        persona: String? = nil,
        instructions: String = ""
    ) throws -> TurgaiAgentProfile {
        let wasEmpty = state.profiles.isEmpty
        let id = Self.uniqueID(for: name, existing: Set(state.profiles.map(\.id)))
        let profile = TurgaiAgentProfile(
            id: id,
            name: name,
            model: model,
            reasoningEffort: reasoningEffort,
            providerConfiguration: providerConfiguration,
            contextWindow: contextWindow,
            persona: persona,
            instructions: instructions
        )
        try Self.validate(profile)
        state.profiles.append(profile)
        if wasEmpty {
            state.defaultProfileID = profile.id
        }
        try persist()
        return profile
    }

    public func delete(id: String) throws {
        guard id != state.defaultProfileID else {
            throw TurgaiAgentProfileError.cannotDeleteDefaultProfile
        }
        guard state.profiles.contains(where: { $0.id == id }) else {
            throw TurgaiAgentProfileError.unknownProfile(id)
        }
        state.profiles.removeAll { $0.id == id }
        try persist()
    }

    private static func validate(_ profile: TurgaiAgentProfile) throws {
        guard Self.validID(profile.id) else {
            throw TurgaiAgentProfileError.invalidID(profile.id)
        }
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            profile.name.count <= 120
        else {
            throw TurgaiAgentProfileError.invalidName
        }
        switch profile.providerConfiguration {
        case .ollama(let baseURL):
            guard profile.model.provider == .ollama, Self.validHTTPURL(baseURL) else {
                throw TurgaiAgentProfileError.invalidEndpointURL(baseURL.absoluteString)
            }
        case .none:
            guard profile.model.provider != .ollama else {
                throw TurgaiAgentProfileError.invalidEndpointURL("")
            }
        }
        guard profile.contextWindow > 0 else {
            throw TurgaiAgentProfileError.invalidContextWindow(profile.contextWindow)
        }
    }

    private static func validateState(_ state: State) throws {
        var ids = Set<String>()
        for profile in state.profiles {
            guard ids.insert(profile.id).inserted else {
                throw TurgaiAgentProfileError.invalidID(profile.id)
            }
            try validate(profile)
        }
    }

    private func persist() throws {
        try files.saveDocument(state, at: Self.statePath)
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 64
            && value.unicodeScalars.allSatisfy {
                $0.isASCII
                    && ($0 == "_" || $0 == "." || ("a"..."z").contains(String($0)) || ("A"..."Z").contains(String($0))
                        || ("0"..."9").contains(String($0)))
            }
    }

    private static func uniqueID(for name: String, existing: Set<String>) -> String {
        let base =
            name
            .lowercased()
            .unicodeScalars
            .map { scalar in
                scalar.isASCII
                    && (scalar == "_" || ("a"..."z").contains(String(scalar)) || ("0"..."9").contains(String(scalar)))
                    ? String(scalar)
                    : "_"
            }
            .joined()
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        let root = base.isEmpty ? "agent" : String(base.prefix(48))
        var candidate = root
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(root)_\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func validHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return false }
        return url.host != nil
    }
}
