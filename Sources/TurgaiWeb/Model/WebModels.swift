public struct TurgaiAgentRuntimeSnapshot: Codable, Sendable, Equatable {
    public let profileID: String
    public let contextID: String
    public let phase: String
    public let currentTool: String?
    public let contextUsedTokens: Int?
    public let contextLimitTokens: Int?
    public let conversationMessageCount: Int
    public let totalTokens: Int?

    public init(
        profileID: String,
        contextID: String,
        phase: String,
        currentTool: String? = nil,
        contextUsedTokens: Int? = nil,
        contextLimitTokens: Int? = nil,
        conversationMessageCount: Int = 0,
        totalTokens: Int? = nil
    ) {
        self.profileID = profileID
        self.contextID = contextID
        self.phase = phase
        self.currentTool = currentTool
        self.contextUsedTokens = contextUsedTokens
        self.contextLimitTokens = contextLimitTokens
        self.conversationMessageCount = conversationMessageCount
        self.totalTokens = totalTokens
    }
}

public struct BotSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let model: String
    public let enabled: Bool

    public init(id: String, name: String, model: String, enabled: Bool) {
        self.id = id
        self.name = name
        self.model = model
        self.enabled = enabled
    }
}

struct BotCard: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let model: String
    let enabled: Bool
    let telegramChatCount: Int
}

public struct TurgaiDashboardSnapshot: Codable, Sendable, Equatable {
    public let profiles: [BotSummary]
    public let runtime: [TurgaiAgentRuntimeSnapshot]

    public init(
        profiles: [BotSummary],
        runtime: [TurgaiAgentRuntimeSnapshot]
    ) {
        self.profiles = profiles
        self.runtime = runtime
    }
}

enum TurgaiAppSection: Sendable {
    case bots
    case tools
    case accounts
}
