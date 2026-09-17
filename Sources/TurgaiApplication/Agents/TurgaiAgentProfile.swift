import Hail
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
public struct TurgaiAgentProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var model: AgentModel
    /// The Ollama server used by this profile, when its model is provided by
    /// Ollama. Other providers do not need an endpoint here.
    public var ollamaBaseURL: URL?
    public var contextWindow: Int
    /// Optional override for Turgai's default voice. Nil keeps the built-in
    /// persona, while an empty string is treated the same way at runtime.
    public var persona: String?
    public var instructions: String
    public var enabled: Bool
    public var telegramChatIDs: [Int64]

    public init(
        id: String,
        name: String,
        model: AgentModel,
        ollamaBaseURL: URL? = nil,
        contextWindow: Int = 16_384,
        persona: String? = nil,
        instructions: String = "",
        enabled: Bool = true,
        telegramChatIDs: [Int64] = []
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.ollamaBaseURL = ollamaBaseURL
        self.contextWindow = contextWindow
        self.persona = persona
        self.instructions = instructions
        self.enabled = enabled
        self.telegramChatIDs = telegramChatIDs
    }
}

public enum TurgaiAgentProfileError: Error, Equatable, Sendable {
    case invalidID(String)
    case invalidName
    case invalidOllamaBaseURL(String)
    case invalidContextWindow(Int)
    case unknownProfile(String)
    case duplicateTelegramChatID(Int64)
    case cannotDeleteDefaultProfile
}

/// Durable catalog and routing table for user-facing agents.
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

    private let stateURL: URL
    private var state: State

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stateURL = directory.appendingPathComponent("profiles.json")
        self.stateURL = stateURL

        let loadedState: State
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let data = try Data(contentsOf: stateURL)
            loadedState = try JSONDecoder().decode(State.self, from: data)
        } else {
            loadedState = State()
        }

        var initialState = loadedState
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
            if canonical.model.provider != .ollama {
                canonical.ollamaBaseURL = nil
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
            try Self.persist(initialState, to: stateURL)
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

    /// Resolves a channel conversation to a profile. Telegram chat IDs are
    /// explicit bindings; all other conversations use the catalog default.
    public func profileID(for conversationID: ConversationID) -> String {
        if conversationID.channel.rawValue == "telegram",
            let chatID = Int64(conversationID.externalAddress.rawValue),
            let profile = state.profiles.first(where: {
                $0.enabled && $0.telegramChatIDs.contains(chatID)
            })
        {
            return profile.id
        }

        return defaultProfile()?.id ?? Self.defaultProfileID
    }

    public func update(_ profile: TurgaiAgentProfile) throws {
        var profile = profile
        if profile.model.provider != .ollama {
            profile.ollamaBaseURL = nil
        }
        try Self.validate(profile)
        guard let index = state.profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw TurgaiAgentProfileError.unknownProfile(profile.id)
        }
        if profile.id == state.defaultProfileID, !profile.enabled {
            throw TurgaiAgentProfileError.invalidName
        }
        try validateUniqueTelegramChatIDs(profile, replacing: profile.id)
        state.profiles[index] = profile
        try persist()
    }

    @discardableResult
    public func create(
        name: String,
        model: AgentModel,
        ollamaBaseURL: URL? = nil,
        contextWindow: Int = TurgaiAgentProfileStore.defaultContextWindow,
        persona: String? = nil,
        instructions: String = "",
        telegramChatIDs: [Int64] = []
    ) throws -> TurgaiAgentProfile {
        let wasEmpty = state.profiles.isEmpty
        let id = Self.uniqueID(for: name, existing: Set(state.profiles.map(\.id)))
        let profile = TurgaiAgentProfile(
            id: id,
            name: name,
            model: model,
            ollamaBaseURL: ollamaBaseURL,
            contextWindow: contextWindow,
            persona: persona,
            instructions: instructions,
            telegramChatIDs: telegramChatIDs
        )
        var canonicalProfile = profile
        if canonicalProfile.model.provider != .ollama {
            canonicalProfile.ollamaBaseURL = nil
        }
        try Self.validate(canonicalProfile)
        try validateUniqueTelegramChatIDs(canonicalProfile, replacing: nil)
        state.profiles.append(canonicalProfile)
        if wasEmpty {
            state.defaultProfileID = canonicalProfile.id
        }
        try persist()
        return canonicalProfile
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
        if profile.model.provider == .ollama {
            guard let ollamaBaseURL = profile.ollamaBaseURL,
                Self.validHTTPURL(ollamaBaseURL)
            else {
                throw TurgaiAgentProfileError.invalidOllamaBaseURL(
                    profile.ollamaBaseURL?.absoluteString ?? ""
                )
            }
        }
        guard profile.contextWindow > 0 else {
            throw TurgaiAgentProfileError.invalidContextWindow(profile.contextWindow)
        }
        guard profile.telegramChatIDs.allSatisfy({ $0 != 0 }) else {
            throw TurgaiAgentProfileError.duplicateTelegramChatID(0)
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
        var telegramChatIDs = Set<Int64>()
        for profile in state.profiles where profile.enabled {
            for chatID in profile.telegramChatIDs {
                guard telegramChatIDs.insert(chatID).inserted else {
                    throw TurgaiAgentProfileError.duplicateTelegramChatID(chatID)
                }
            }
        }
    }

    private func validateUniqueTelegramChatIDs(
        _ profile: TurgaiAgentProfile,
        replacing profileID: String?
    ) throws {
        var used = Set<Int64>()
        for existing in state.profiles where existing.id != profileID && existing.enabled {
            used.formUnion(existing.telegramChatIDs)
        }
        for chatID in profile.telegramChatIDs {
            guard used.insert(chatID).inserted else {
                throw TurgaiAgentProfileError.duplicateTelegramChatID(chatID)
            }
        }
    }

    private func persist() throws {
        try Self.persist(state, to: stateURL)
    }

    private static func persist(_ state: State, to stateURL: URL) throws {
        let data = try JSONEncoder.pretty.encode(state)
        try data.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
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

extension JSONEncoder {
    fileprivate static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
