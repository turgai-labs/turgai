import Hail

public struct HailRuntimeConfiguration: Sendable {
    public let temperature: Double
    public let contextWindow: Int?
    /// Optional per-model context capacities. Hosts can use this when
    /// several user-facing profiles share one runtime but have different
    /// context budgets.
    public let modelContextWindows: [AgentModel: Int]
    public let compactionMaxOutputTokens: Int
    public let maxToolRounds: Int

    public init(
        temperature: Double = 0.2,
        contextWindow: Int? = nil,
        modelContextWindows: [AgentModel: Int] = [:],
        compactionMaxOutputTokens: Int = 8_192,
        maxToolRounds: Int = 16
    ) {
        self.temperature = temperature
        self.contextWindow = contextWindow
        self.modelContextWindows = modelContextWindows
        self.compactionMaxOutputTokens = compactionMaxOutputTokens
        self.maxToolRounds = maxToolRounds
    }

    public func makeAgentRuntimePlugin(
        defaultModel: AgentModel,
        workspaceRoot: String,
        modelEndpointProvider: ModelEndpointProvider? = nil,
        definitionProvider: AgentRuntimePlugin.DefinitionProvider? = nil,
        turnToolsProvider: AgentRuntimePlugin.TurnToolsProvider? = nil,
        authorityProvider: AgentRuntimePlugin.AuthorityProvider? = nil,
        compactionOperation: CompactionOperation? = nil
    ) throws -> AgentRuntimePlugin {
        let routerConfiguration = try ModelRouterConfiguration(
            temperature: temperature,
            contextWindowResolver: ModelContextWindowResolver(
                configured: { candidate in
                    if candidate == defaultModel, let contextWindow {
                        return contextWindow
                    }
                    return modelContextWindows[candidate]
                }
            )
        )

        return try AgentRuntimePlugin(
            defaultModel: defaultModel,
            maxToolRounds: maxToolRounds,
            routerConfiguration: routerConfiguration,
            modelEndpointProvider: modelEndpointProvider,
            turnToolsProvider: turnToolsProvider,
            authorityProvider: authorityProvider,
            workspaceProvider: { _ in
                AgentWorkspace(rootPath: workspaceRoot)
            },
            definitionProvider: definitionProvider,
            contextCompactor: SlidingWindowCompactor(
                threshold: 0.55,
                keepRecent: 6,
                outputReserve: compactionMaxOutputTokens
            ),
            compactionOperation: compactionOperation
        )
    }
}
