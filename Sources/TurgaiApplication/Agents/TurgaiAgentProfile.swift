import AnyLanguageModel
import Hail
import TurgaiPersistence
import TurgaiDomain

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

public struct AgentCredentialReference: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> Self {
        Self(rawValue: UUID().uuidString)
    }
}

public enum OpenAICompatibleAPI: String, Codable, Sendable, Equatable {
    case chatCompletions
    case responses
}

#if Llama
    public struct LlamaCPPConfiguration: Codable, Sendable, Equatable {
        public let modelPath: String
        public let gpuLayers: Int32

        public init(modelPath: String, gpuLayers: Int32 = -1) {
            self.modelPath = modelPath
            self.gpuLayers = gpuLayers
        }
    }
#endif

/// Complete provider-owned configuration for a profile. Each case carries
/// exactly the values required to construct that provider for a turn,
/// including its context window where that is the user's choice.
public enum AgentProviderConfiguration: Codable, Sendable, Equatable {
    case ollama(baseURL: URL, contextWindow: Int)
    case openAI(credential: AgentCredentialReference, contextWindow: Int)
    case anthropic(credential: AgentCredentialReference, contextWindow: Int)
    case gemini(credential: AgentCredentialReference, contextWindow: Int)
    case openAICompatible(
        baseURL: URL,
        credential: AgentCredentialReference,
        api: OpenAICompatibleAPI,
        contextWindow: Int
    )
    /// Apple's on-device model. Its context window isn't a setting: the model
    /// reports it, and it differs between OS releases.
    case appleSystem
    #if Llama
        case llamaCPP(LlamaCPPConfiguration, contextWindow: Int)
    #endif
}

extension AgentProviderConfiguration {
    public var credentialReference: AgentCredentialReference? {
        switch self {
        case .openAI(let reference, _), .anthropic(let reference, _), .gemini(let reference, _):
            return reference
        case .openAICompatible(_, let reference, _, _):
            return reference
        case .ollama, .appleSystem:
            return nil
        #if Llama
            case .llamaCPP:
                return nil
        #endif
        }
    }

    /// How many tokens a prompt may use with this provider.
    public var contextWindow: Int {
        switch self {
        case .ollama(_, let window), .openAI(_, let window), .anthropic(_, let window),
            .gemini(_, let window), .openAICompatible(_, _, _, let window):
            return window
        #if Llama
            case .llamaCPP(_, let window):
                return window
        #endif
        case .appleSystem:
            return Self.appleSystemContextWindow
        }
    }

    /// The on-device model's own context window.
    public static var appleSystemContextWindow: Int {
        #if canImport(FoundationModels)
            SystemLanguageModel.default.contextSize
        #else
            0
        #endif
    }
}

public struct TurgaiAgentProfile: Codable, Equatable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id, name, model, reasoningEffort, providerConfiguration, persona, instructions,
            availability
    }

    public let id: String
    public var name: String
    public var model: AgentModel
    /// Optional provider-facing reasoning effort. Nil delegates the choice to
    /// the selected model provider.
    public var reasoningEffort: ReasoningEffort?
    public var providerConfiguration: AgentProviderConfiguration
    /// How many tokens a prompt may use, as the provider configuration says.
    public var contextWindow: Int { providerConfiguration.contextWindow }
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
        persona: String? = nil,
        instructions: String = "",
        availability: AgentAvailability = .enabled
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.providerConfiguration = providerConfiguration
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
/// The profiles are kept in their storage, and every read asks it: the store keeps no copy.
/// What must hold across profiles, one default that exists, is the storage's.
public actor TurgaiAgentProfileStore {
    public static let defaultProfileID = "conversation"
    /// The context window a new profile starts with, for providers where it's a choice.
    public static let defaultContextWindow = 16_384

    private let storage: AgentProfileStorage

    /// The profiles kept in `storage`.
    public init(storage: AgentProfileStorage) {
        self.storage = storage
    }

    /// Every profile, by name.
    public func profiles() async throws -> [TurgaiAgentProfile] {
        try await storage.all()
    }

    public func profile(id: String) async throws -> TurgaiAgentProfile? {
        try await storage.withID(id)
    }

    public func defaultProfile() async throws -> TurgaiAgentProfile? {
        try await storage.defaultProfile()
    }

    public func isDefaultProfile(id: String) async throws -> Bool {
        try await storage.defaultProfile()?.id == id
    }

    public func setDefaultProfile(id: String) async throws {
        guard let profile = try await storage.withID(id) else {
            throw TurgaiAgentProfileError.unknownProfile(id)
        }
        guard case .enabled = profile.availability else {
            throw TurgaiAgentProfileError.invalidName
        }
        try await storage.setDefault(id)
    }

    /// Resolves the configured default agent. Channel-specific routing is
    /// owned by the channel actor and never inferred from this catalog.
    public func defaultProfileID() async throws -> String {
        guard let profile = try await storage.defaultProfile(), profile.availability == .enabled else {
            throw TurgaiAgentProfileError.noEnabledProfile
        }
        return profile.id
    }

    public func update(_ profile: TurgaiAgentProfile) async throws {
        try Self.validate(profile)
        if case .disabled = profile.availability, try await isDefaultProfile(id: profile.id) {
            throw TurgaiAgentProfileError.invalidName
        }
        guard try await storage.update(profile) else {
            throw TurgaiAgentProfileError.unknownProfile(profile.id)
        }
    }

    /// Makes a profile: the first one made is the default.
    @discardableResult
    public func create(
        name: String,
        model: AgentModel,
        reasoningEffort: ReasoningEffort? = nil,
        providerConfiguration: AgentProviderConfiguration,
        persona: String? = nil,
        instructions: String = ""
    ) async throws -> TurgaiAgentProfile {
        let profile = TurgaiAgentProfile(
            id: Self.uniqueID(for: name, existing: try await storage.ids()),
            name: name,
            model: model,
            reasoningEffort: reasoningEffort,
            providerConfiguration: providerConfiguration,
            persona: persona,
            instructions: instructions
        )
        try Self.validate(profile)
        try await storage.insert(profile)
        return profile
    }

    public func delete(id: String) async throws {
        guard try await !isDefaultProfile(id: id) else {
            throw TurgaiAgentProfileError.cannotDeleteDefaultProfile
        }
        guard try await storage.delete(id) else {
            throw TurgaiAgentProfileError.unknownProfile(id)
        }
    }

    private static func validate(_ profile: TurgaiAgentProfile) throws {
        guard Self.validID(profile.id) else {
            throw TurgaiAgentProfileError.invalidID(profile.id)
        }
        guard !profile.name.trimmed().isEmpty,
            profile.name.count <= 120
        else {
            throw TurgaiAgentProfileError.invalidName
        }
        switch profile.providerConfiguration {
        case .ollama(let baseURL, _):
            guard profile.model.provider == .ollama, Self.validHTTPURL(baseURL) else {
                throw TurgaiAgentProfileError.invalidEndpointURL(baseURL.absoluteString)
            }
        case .openAI:
            guard profile.model.provider == .openAI else { throw TurgaiAgentProfileError.invalidEndpointURL("") }
        case .anthropic:
            guard profile.model.provider == .anthropic else {
                throw TurgaiAgentProfileError.invalidEndpointURL("")
            }
        case .gemini:
            guard profile.model.provider == .gemini else { throw TurgaiAgentProfileError.invalidEndpointURL("") }
        case .openAICompatible(let baseURL, _, _, _):
            guard profile.model.provider == .openAICompatible, Self.validHTTPURL(baseURL) else {
                throw TurgaiAgentProfileError.invalidEndpointURL(baseURL.absoluteString)
            }
        case .appleSystem:
            guard profile.model.provider == .system else { throw TurgaiAgentProfileError.invalidEndpointURL("") }
        #if Llama
            case .llamaCPP(let configuration, _):
                guard profile.model.provider == .llamaCPP,
                    !configuration.modelPath.trimmed().isEmpty
                else {
                    throw TurgaiAgentProfileError.invalidEndpointURL(configuration.modelPath)
                }
        #endif
        }
        guard profile.contextWindow > 0 else {
            throw TurgaiAgentProfileError.invalidContextWindow(profile.contextWindow)
        }
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
