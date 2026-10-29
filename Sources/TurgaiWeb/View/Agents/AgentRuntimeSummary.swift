import AnyLanguageModel
import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
    import FoundationInternationalization
#else
    import Foundation
#endif

struct AgentRuntimeSummary: HTML, Sendable {
    let profile: TurgaiAgentProfile
    let runtime: [TurgaiAgentRuntimeSnapshot]

    var body: some HTML {
        aside(.class("detail-aside")) {
            h2 { "Live" }
            if let active = runtime.first {
                LiveTurn(snapshot: active)
            } else {
                div(.class("live-state live-state-idle")) {
                    span(.class("live-dot")) {}
                    strong { "idle" }
                }
                p(.class("section-intro")) { "No active conversation." }
            }
            div(.class("detail-facts detail-facts-bottom")) {
                Fact(label: "Routing", value: "Selected per channel")
                Fact(label: "Context limit", value: "\(profile.contextWindow.formatted()) tokens")
            }
        }
    }
}

/// What the agent is doing in the conversation it's in now.
private struct LiveTurn: HTML, Sendable {
    let snapshot: TurgaiAgentRuntimeSnapshot

    private var window: String? {
        guard let used = snapshot.contextUsedTokens, let limit = snapshot.contextLimitTokens else { return nil }
        return "\(used.formatted()) / \(limit.formatted())"
    }

    var body: some HTML {
        div(.class("live-state")) {
            span(.class("live-dot")) {}
            strong { snapshot.phase.rawValue }
        }
        div(.class("detail-facts")) {
            Fact(label: "Context", value: snapshot.contextID)
            if let currentTool = snapshot.currentTool { Fact(label: "Tool", value: currentTool) }
            if let window { Fact(label: "Window", value: window) }
            Fact(label: "Turns", value: snapshot.historyTurnCount.formatted())
        }
    }
}

/// One labelled fact.
private struct Fact: HTML, Sendable {
    let label: String
    let value: String

    var body: some HTML {
        p {
            span(.class("fact-label")) { label }
            value
        }
    }
}
