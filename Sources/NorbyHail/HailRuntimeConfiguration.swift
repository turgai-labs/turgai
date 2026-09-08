import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct HailRuntimeConfiguration: Sendable {
    public let modelRoute: String
    public let ollamaBaseURL: URL
    public let temperature: Double
    public let contextWindow: Int?
    public let compactionMaxOutputTokens: Int
    public let maxToolRounds: Int
    public let snapshotPolicy: AgentSnapshotPolicy

    public init(
        modelRoute: String = "ollama/qwen3.5:9b",
        ollamaBaseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        temperature: Double = 0.2,
        contextWindow: Int? = nil,
        compactionMaxOutputTokens: Int = 8_192,
        maxToolRounds: Int = 16,
        snapshotPolicy: AgentSnapshotPolicy = .periodicOrWhenCompacted(
            every: 50,
            retention: .keepLast(2)
        )
    ) {
        self.modelRoute = modelRoute
        self.ollamaBaseURL = ollamaBaseURL
        self.temperature = temperature
        self.contextWindow = contextWindow
        self.compactionMaxOutputTokens = compactionMaxOutputTokens
        self.maxToolRounds = maxToolRounds
        self.snapshotPolicy = snapshotPolicy
    }

    public func makeAgentRuntimePlugin(
        workspaceRoot: String,
        definitionProvider: AgentRuntimePlugin.DefinitionProvider? = nil,
        turnToolsProvider: AgentRuntimePlugin.TurnToolsProvider? = nil,
        authorityProvider: AgentRuntimePlugin.AuthorityProvider? = nil
    ) throws -> AgentRuntimePlugin {
        let model = try AgentModelReference(modelRoute)
        let routerConfiguration = try ModelRouterConfiguration(
            temperature: temperature,
            baseURLs: [.ollama: ollamaBaseURL],
            contextWindowResolver: ModelContextWindowResolver(
                configured: { route in
                    guard route.identifier == model.rawValue else { return nil }
                    return contextWindow
                },
                discovered: { route, baseURL in
                    guard route.provider == .ollama else { return nil }
                    return try await OllamaContextWindowProvider.resolve(
                        model: route.model,
                        baseURL: baseURL
                    )
                }
            ),
            // Verified for the local Ollama runner: "no reasoning" maps to
            // the boolean think switch. Graded levels stay undeclared.
            reasoningCapabilities: [
                model: ModelReasoningCapabilities(levels: [
                    ModelReasoningLevel(effort: .none, encoding: .disabled)
                ])
            ]
        )

        return try AgentRuntimePlugin(
            defaultModel: model,
            maxToolRounds: maxToolRounds,
            routerConfiguration: routerConfiguration,
            turnToolsProvider: turnToolsProvider,
            authorityProvider: authorityProvider,
            workspaceProvider: { _ in
                AgentWorkspace(rootPath: workspaceRoot)
            },
            definitionProvider: definitionProvider,
            contextCompactor: SlidingWindowCompactor(
                outputReserve: compactionMaxOutputTokens
            )
        )
    }
}
