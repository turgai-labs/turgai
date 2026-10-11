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
                div(.class("live-state")) {
                    span(.class("live-dot")) {}
                    strong { active.phase.rawValue }
                }
                div(.class("detail-facts")) {
                    p {
                        span(.class("fact-label")) { "Context" }
                        active.contextID
                    }
                    if let currentTool = active.currentTool {
                        p {
                            span(.class("fact-label")) { "Tool" }
                            currentTool
                        }
                    }
                    if let used = active.contextUsedTokens, let limit = active.contextLimitTokens {
                        p {
                            span(.class("fact-label")) { "Window" }
                            "\(used.formatted()) / \(limit.formatted())"
                        }
                    }
                    p {
                        span(.class("fact-label")) { "Turns" }
                        active.historyTurnCount.formatted()
                    }
                }
            } else {
                div(.class("live-state live-state-idle")) {
                    span(.class("live-dot")) {}
                    strong { "idle" }
                }
                p(.class("section-intro")) { "No active conversation." }
            }
            div(.class("detail-facts detail-facts-bottom")) {
                p {
                    span(.class("fact-label")) { "Routing" }
                    "Selected per channel"
                }
                p {
                    span(.class("fact-label")) { "Context limit" }
                    "\(profile.contextWindow.formatted()) tokens"
                }
            }
        }
    }
}
