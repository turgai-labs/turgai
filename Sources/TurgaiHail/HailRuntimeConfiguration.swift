import DistributedCluster
import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Turns a logical `WorkspaceID` into a safe, stable directory name.
///
/// A `WorkspaceID`'s raw value can trace back to externally supplied
/// identifiers (a Telegram chat id, a web account id, in principle anything a
/// caller chooses to build one from) and must never be trusted as path input
/// directly — a value containing "..", "/", or other special characters must
/// not be able to walk the resolved directory outside `workspaceRoot`.
///
/// Each "/"-separated segment is allow-listed down to
/// `[A-Za-z0-9_.-]` (with a segment that is only "." or ".." rejected
/// outright, not just filtered), and a short stable hash of the *full*
/// original value is always appended, so two different ids that happen to
/// sanitize to the same visible text still land in different directories.
/// The hash need not be cryptographic: nothing here is a target for a
/// deliberate preimage/collision search, since a `WorkspaceID`'s value space
/// is controlled by the host, not chosen by a model or other untrusted input.
private enum WorkspaceDirectoryName {
    static func make(for id: WorkspaceID) -> String {
        let raw = id.rawValue
        let segments = raw.split(separator: "/", omittingEmptySubsequences: true)
        let sanitized = segments.map(sanitize).prefix(4).joined(separator: "-")
        let digest = fnv1a(raw)
        return sanitized.isEmpty ? digest : "\(sanitized)-\(digest)"
    }

    private static func sanitize(_ segment: Substring) -> String {
        let cleaned = String(
            segment.map { character -> Character in
                character.isASCII
                    && (character.isLetter || character.isNumber || character == "_" || character == "-"
                        || character == ".")
                    ? character : "_"
            }
        )
        return cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) ? "_" : cleaned
    }

    /// FNV-1a, 64-bit: fast, dependency-free, and stable across process
    /// restarts (unlike `Hasher`, whose seed is randomized per run).
    private static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

public struct HailRuntimeConfiguration: Sendable {
    public let temperature: Double
    public let contextWindow: Int?
    public let compactionMaxOutputTokens: Int
    public let maxToolRounds: Int
    public let ollamaKeepAlive: String?

    public init(
        temperature: Double = 0.2,
        contextWindow: Int? = nil,
        compactionMaxOutputTokens: Int = 8_192,
        maxToolRounds: Int = 64,
        ollamaKeepAlive: String? = "10m"
    ) {
        self.temperature = temperature
        self.contextWindow = contextWindow
        self.compactionMaxOutputTokens = compactionMaxOutputTokens
        self.maxToolRounds = maxToolRounds
        self.ollamaKeepAlive = ollamaKeepAlive
    }

    public func makeAgentRuntimePlugin(
        workspaceRoot: String,
        spawnConfigProvider: @escaping AgentRuntimePlugin.SpawnConfigProvider,
        modelEndpointProvider: AgentRuntimePlugin.ModelEndpointProvider? = nil,
        modelSelectionProvider: @escaping AgentRuntimePlugin.ModelSelectionProvider,
        definitionProvider: AgentRuntimePlugin.DefinitionProvider? = nil,
        turnToolsProvider: AgentRuntimePlugin.TurnToolsProvider? = nil,
        authority: @escaping @Sendable (ClusterSystem) -> any Authority,
        compactionOperation: CompactionOperation? = nil
    ) throws -> AgentRuntimePlugin {
        let routerConfiguration = try ModelRouterConfiguration(
            temperature: temperature,
            contextWindowResolver: ModelContextWindowResolver(configured: { _, _ in contextWindow })
        )

        return try AgentRuntimePlugin(
            maxToolRounds: maxToolRounds,
            routerConfiguration: routerConfiguration,
            modelEndpointProvider: modelEndpointProvider,
            turnToolsProvider: turnToolsProvider,
            authority: authority,
            workspaceProvider: { spawnConfig throws(AgentRuntimeError) in
                let directoryName = WorkspaceDirectoryName.make(for: spawnConfig.workspaceID)
                let root = workspaceRoot + "/workspaces/" + directoryName
                do {
                    try FileManager.default.createDirectory(
                        atPath: root,
                        withIntermediateDirectories: true
                    )
                } catch {
                    throw AgentRuntimeError.configurationError(
                        "Could not create workspace directory '\(root)': \(error)"
                    )
                }
                return AgentWorkspace(rootPath: root)
            },
            spawnConfigProvider: spawnConfigProvider,
            definitionProvider: definitionProvider,
            modelSelectionProvider: modelSelectionProvider,
            contextCompactor: SlidingWindowCompactor(outputReserve: compactionMaxOutputTokens),
            compactionOperation: compactionOperation,
            modelReasoningPolicy: ReasoningPolicy.thinkWhenDeciding
        )
    }
}

/// When a model thinks before it answers.
public enum ReasoningPolicy {
    /// Think when deciding, not when executing: on a turn's first round, and after a tool call
    /// failed, but not on the rounds that carry out the plan. Requests without tools, and
    /// profiles that fix their own reasoning, keep the provider's behavior.
    public static func thinkWhenDeciding(_ context: ModelReasoningContext) -> ModelReasoningOverride {
        guard context.purpose == .generation, context.hasTools else { return .providerDefault }
        switch context.lastToolRound {
        case nil, .failed: return .enabled
        case .succeeded: return .disabled
        }
    }
}
