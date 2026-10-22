import AnyLanguageModel
import Foundation
import Hail
import TurgaiPersistence

extension AgentProviderConfiguration {
    /// The provider account `model`'s requests count against, which a request limit is set for:
    /// `nil` for a model that runs on this machine without HTTP.
    public func account(for model: AgentModel) -> ModelAccount? {
        switch self {
        case .ollama(let baseURL, _):
            // A cloud model is the account's, whichever server passes its requests on.
            let name = model.id.rawValue
            if name.hasSuffix(":cloud") || name.hasSuffix("-cloud") { return ModelAccount(rawValue: "ollama-cloud") }
            return ModelAccount(rawValue: "ollama@\(baseURL.host() ?? baseURL.absoluteString)")
        case .openAI: return ModelAccount(rawValue: "openai")
        case .anthropic: return ModelAccount(rawValue: "anthropic")
        case .gemini: return ModelAccount(rawValue: "gemini")
        case .openAICompatible(let baseURL, _, _, _):
            return ModelAccount(rawValue: baseURL.host() ?? baseURL.absoluteString)
        case .appleSystem, .llamaCPP: return nil
        }
    }
}

/// How many requests each provider account takes at once, as the dashboard sets them, and the
/// transports models send their requests with, which follow them as they change.
public actor RequestLimitStore {
    /// What a new installation starts with: Ollama's cloud takes one request at a time on its
    /// free plan.
    public static let defaultLimits: [ModelAccount: Int] = [ModelAccount(rawValue: "ollama-cloud"): 1]

    private static let statePath = "agents/request-limits.json"

    private let files: FileClient
    private var limits: [ModelAccount: Int]
    /// The transports models send their requests with.
    public nonisolated let transports: ModelTransports

    public init(files: FileClient) throws {
        self.files = files
        let stored: [String: Int]? = try files.loadDocument(at: Self.statePath)
        let limits =
            stored.map { Dictionary(uniqueKeysWithValues: $0.map { (ModelAccount(rawValue: $0.key), $0.value) }) }
            ?? Self.defaultLimits
        self.limits = limits
        self.transports = ModelTransports(limits: limits)
    }

    /// `account`'s limit; `nil` when its requests aren't limited.
    public func limit(for account: ModelAccount) -> Int? {
        limits[account]
    }

    /// Sets `account`'s limit, at least one; `nil` lifts it. Models use it from their next request.
    public func setLimit(_ limit: Int?, for account: ModelAccount) async throws {
        let limit = limit.map { max(1, $0) }
        limits[account] = limit
        try files.saveDocument(
            Dictionary(uniqueKeysWithValues: limits.map { ($0.key.rawValue, $0.value) }), at: Self.statePath)
        await transports.setLimit(limit, for: account)
    }
}
