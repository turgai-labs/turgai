import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct HailRuntimeConfiguration: Sendable {
    public let modelIdentifier: String
    public let ollamaBaseURL: URL
    public let temperature: Double
    public let contextWindow: Int?
    public let compactionMaxOutputTokens: Int
    public let maxToolRounds: Int

    public init(
        modelIdentifier: String = "ollama/qwen3.5:9b",
        ollamaBaseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        temperature: Double = 0.2,
        contextWindow: Int? = nil,
        compactionMaxOutputTokens: Int = 8_192,
        maxToolRounds: Int = 16
    ) {
        self.modelIdentifier = modelIdentifier
        self.ollamaBaseURL = ollamaBaseURL
        self.temperature = temperature
        self.contextWindow = contextWindow
        self.compactionMaxOutputTokens = compactionMaxOutputTokens
        self.maxToolRounds = maxToolRounds
    }

    public func makeAgentRuntimePlugin(
        workspaceRoot: String,
        definitionProvider: AgentRuntimePlugin.DefinitionProvider? = nil,
        turnToolsProvider: AgentRuntimePlugin.TurnToolsProvider? = nil,
        authorityProvider: AgentRuntimePlugin.AuthorityProvider? = nil,
        compactionOperation: CompactionOperation? = nil
    ) throws -> AgentRuntimePlugin {
        let model = try AgentModel(modelIdentifier)
        let routerConfiguration = try ModelRouterConfiguration(
            temperature: temperature,
            baseURLs: [.ollama: ollamaBaseURL],
            contextWindowResolver: ModelContextWindowResolver(
                configured: { candidate in
                    guard candidate.identifier == model.identifier else { return nil }
                    return contextWindow
                },
                discovered: { candidate, baseURL in
                    guard candidate.provider == .ollama else { return nil }
                    return try await OllamaContextWindowProvider.resolve(
                        model: candidate.id.rawValue,
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
                threshold: 0.55,
                keepRecent: 6,
                outputReserve: compactionMaxOutputTokens
            ),
            compactionOperation: compactionOperation
        )
    }
}
