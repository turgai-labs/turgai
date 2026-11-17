import AnyLanguageModel
import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct AgentTile: HTML, Sendable {
    /// The space whose bot it is.
    let space: SpaceID
    let profile: BotCard
    let runtime: [TurgaiAgentRuntimeSnapshot]

    private var initial: String {
        profile.name.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some HTML {
        a(
            .href("/spaces/\(space.rawValue.uuidString)/bots/\(profile.id)"), .class("bot-tile"),
            .init(name: "data-agent-id", value: profile.id)
        ) {
            div(.class("bot-tile-top")) {
                span(.class("bot-mark")) { initial }
                span(.class("bot-status"), .init(name: "data-runtime-status", value: "")) {
                    runtime.isEmpty ? "idle" : "active"
                }
            }
            h2 { profile.name }
            p(.class("bot-model")) { profile.model }
            div(.class("bot-tile-bottom")) {
                span { "Chat, or see how it works" }
                span(.class("tile-arrow")) { "→" }
            }
        }
    }
}
