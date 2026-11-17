import Hail
import TurgaiApplication

public struct TurgaiAgentRuntimeSnapshot: Codable, Sendable, Equatable {
    public let profileID: String
    public let contextID: String
    public let phase: AgentRuntimeState
    public let currentTool: String?
    public let contextUsedTokens: Int?
    public let contextLimitTokens: Int?
    public let historyTurnCount: Int
    public let totalTokens: Int?

    public init(
        profileID: String,
        contextID: String,
        phase: AgentRuntimeState,
        currentTool: String? = nil,
        contextUsedTokens: Int? = nil,
        contextLimitTokens: Int? = nil,
        historyTurnCount: Int = 0,
        totalTokens: Int? = nil
    ) {
        self.profileID = profileID
        self.contextID = contextID
        self.phase = phase
        self.currentTool = currentTool
        self.contextUsedTokens = contextUsedTokens
        self.contextLimitTokens = contextLimitTokens
        self.historyTurnCount = historyTurnCount
        self.totalTokens = totalTokens
    }
}

public struct BotSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let model: String

    public init(id: String, name: String, model: String) {
        self.id = id
        self.name = name
        self.model = model
    }
}

struct BotCard: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let model: String
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
    /// Your spaces, and each space's pages.
    case spaces
    /// The server's tools.
    case tools
    /// The server's accounts.
    case accounts
}
