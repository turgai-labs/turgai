import AnyLanguageModel
import Hail
import TurgaiDomain
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

public struct AgentCredentialReference: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> Self {
        Self(rawValue: UUID().uuidString)
    }
}

public struct TurgaiAgentProfile: Codable, Equatable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id, name, modelID, reasoningEffort, providerConfiguration, persona, instructions, availability
    }

    public let id: String
    public var name: String
    /// Where its model runs, and what reaching it takes.
    public private(set) var providerConfiguration: AgentProviderConfiguration
    /// Its model: the provider's, as the configuration says, by the ID the provider knows it by.
    public private(set) var model: AgentModel
    /// Optional provider-facing reasoning effort. Nil delegates the choice to
    /// the selected model provider.
    public var reasoningEffort: ReasoningEffort?
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
        providerConfiguration: AgentProviderConfiguration,
        modelID: AgentModelID,
        reasoningEffort: ReasoningEffort? = nil,
        persona: String? = nil,
        instructions: String = "",
        availability: AgentAvailability = .enabled
    ) throws(AgentModelError) {
        self.id = id
        self.name = name
        self.providerConfiguration = providerConfiguration
        self.model = try AgentModel(provider: providerConfiguration.provider.modelProvider, id: modelID)
        self.reasoningEffort = reasoningEffort
        self.persona = persona
        self.instructions = instructions
        self.availability = availability
    }

    /// Runs `id` where `configuration` says from now on: the two change together.
    public mutating func use(_ configuration: AgentProviderConfiguration, model id: AgentModelID)
        throws(AgentModelError)
    {
        model = try AgentModel(provider: configuration.provider.modelProvider, id: id)
        providerConfiguration = configuration
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try values.decode(String.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            providerConfiguration: try values.decode(AgentProviderConfiguration.self, forKey: .providerConfiguration),
            modelID: try values.decode(AgentModelID.self, forKey: .modelID),
            reasoningEffort: try values.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort),
            persona: try values.decodeIfPresent(String.self, forKey: .persona),
            instructions: try values.decode(String.self, forKey: .instructions),
            availability: try values.decode(AgentAvailability.self, forKey: .availability)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(providerConfiguration, forKey: .providerConfiguration)
        try values.encode(model.id, forKey: .modelID)
        try values.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try values.encodeIfPresent(persona, forKey: .persona)
        try values.encode(instructions, forKey: .instructions)
        try values.encode(availability, forKey: .availability)
    }
}

public enum TurgaiAgentProfileError: Error, Equatable, Sendable {
    case invalidID(String)
    case invalidName
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
        providerConfiguration: AgentProviderConfiguration,
        modelID: AgentModelID,
        reasoningEffort: ReasoningEffort? = nil,
        persona: String? = nil,
        instructions: String = ""
    ) async throws -> TurgaiAgentProfile {
        let profile = try TurgaiAgentProfile(
            id: Self.uniqueID(for: name, existing: try await storage.ids()),
            name: name,
            providerConfiguration: providerConfiguration,
            modelID: modelID,
            reasoningEffort: reasoningEffort,
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
}
