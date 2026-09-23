import Hail

public struct HailRuntimeConfiguration: Sendable {
    public let temperature: Double
    public let contextWindow: Int?
    /// Optional per-model context capacities. Hosts can use this when
    /// several user-facing profiles share one runtime but have different
    /// context budgets.
    public let modelContextWindows: [AgentModel: Int]
    public let contextWindowProvider: (@Sendable (AgentModel, AgentID) async -> Int?)?
    public let compactionMaxOutputTokens: Int
    public let maxToolRounds: Int
    public let ollamaKeepAlive: String?

    public init(
        temperature: Double = 0.2,
        contextWindow: Int? = nil,
        modelContextWindows: [AgentModel: Int] = [:],
        contextWindowProvider: (@Sendable (AgentModel, AgentID) async -> Int?)? = nil,
        compactionMaxOutputTokens: Int = 8_192,
        maxToolRounds: Int = 16,
        ollamaKeepAlive: String? = "10m"
    ) {
        self.temperature = temperature
        self.contextWindow = contextWindow
        self.modelContextWindows = modelContextWindows
        self.contextWindowProvider = contextWindowProvider
        self.compactionMaxOutputTokens = compactionMaxOutputTokens
        self.maxToolRounds = maxToolRounds
        self.ollamaKeepAlive = ollamaKeepAlive
    }

    public func makeAgentRuntimePlugin(
        workspaceRoot: String,
        modelEndpointProvider: ModelEndpointProvider? = nil,
        modelSelectionProvider: @escaping ModelSelectionProvider,
        definitionProvider: AgentRuntimePlugin.DefinitionProvider? = nil,
        turnToolsProvider: AgentRuntimePlugin.TurnToolsProvider? = nil,
        authorityProvider: AgentRuntimePlugin.AuthorityProvider? = nil,
        compactionOperation: CompactionOperation? = nil
    ) throws -> AgentRuntimePlugin {
        let routerConfiguration = try ModelRouterConfiguration(
            temperature: temperature,
            contextWindowResolver: ModelContextWindowResolver(
                configured: { candidate, agentID in
                    if let contextWindowProvider {
                        // A host provider is authoritative. If it cannot
                        // resolve this agent/model pair, preserve that miss
                        // instead of falling back to another profile's model
                        // value.
                        return await contextWindowProvider(candidate, agentID)
                    }
                    return modelContextWindows[candidate] ?? contextWindow
                }
            )
        )

        return try AgentRuntimePlugin(
            maxToolRounds: maxToolRounds,
            routerConfiguration: routerConfiguration,
            mcpServerConfiguration: nil,
            modelEndpointProvider: modelEndpointProvider,
            turnToolsProvider: turnToolsProvider,
            authorityProvider: authorityProvider,
            workspaceProvider: { _ in
                AgentWorkspace(rootPath: workspaceRoot)
            },
            definitionProvider: definitionProvider,
            modelSelectionProvider: modelSelectionProvider,
            contextCompactor: SlidingWindowCompactor(
                threshold: 0.55,
                keepRecent: 6,
                outputReserve: compactionMaxOutputTokens
            ),
            compactionOperation: compactionOperation,
        )
    }
}
