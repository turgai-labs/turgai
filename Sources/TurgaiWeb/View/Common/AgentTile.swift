import AnyLanguageModel
import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence
import TurgaiTelegram

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
                    profile.enabled ? (runtime.isEmpty ? "idle" : "active") : "paused"
                }
            }
            h2 { profile.name }
            p(.class("bot-model")) { profile.model }
            div(.class("bot-tile-bottom")) {
                span {
                    profile.telegramChatCount == 0
                        ? "Telegram · default"
                        : "Telegram · \(profile.telegramChatCount) chat(s)"
                }
                span(.class("tile-arrow")) { "→" }
            }
        }
    }
}
