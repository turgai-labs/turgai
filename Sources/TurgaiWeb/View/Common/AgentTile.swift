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

struct AgentTile: HTML, Sendable {
    let profile: BotCard
    let runtime: [TurgaiAgentRuntimeSnapshot]

    private var initial: String {
        profile.name.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some HTML {
        a(.href("/agents/\(profile.id)"), .class("bot-tile"), .init(name: "data-agent-id", value: profile.id)) {
            div(.class("bot-tile-top")) {
                span(.class("bot-mark")) { initial }
                span(.class("bot-status"), .init(name: "data-runtime-status", value: "")) {
                    switch profile.availability {
                    case .enabled: runtime.isEmpty ? "idle" : "active"
                    case .disabled: "paused"
                    }
                }
            }
            h2 { profile.name }
            p(.class("bot-model")) { profile.model }
            div(.class("bot-tile-bottom")) {
                span {
                    "Routing is configured per channel"
                }
                span(.class("tile-arrow")) { "→" }
            }
        }
    }
}
