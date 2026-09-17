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

struct TelegramPage: HTMLDocument, Sendable {
    let chatIDs: [Int64]
    let error: String?

    init(chatIDs: [Int64] = [], error: String? = nil) {
        self.chatIDs = chatIDs
        self.error = error
    }
    var title: String { "Turgai — Telegram" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            div(.class("setup-shell")) {
                SetupHeader()
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "A way to reach you" }
                        h1 { "Meet Turgai somewhere familiar." }
                        p(.class("lede")) {
                            "Connect Telegram if you want Turgai to meet you there. You can choose who it listens to."
                        }
                    }
                    div(.class("setup-form-area")) {
                        if let error { p(.class("error")) { error } }
                        form(
                            .method(.post), .action("/onboarding/telegram"),
                            .init(name: "id", value: "telegram-form")
                        ) {
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Bot token" }
                                input(
                                    .type(.text), .name("token"), .autocomplete("off"),
                                    .init(name: "autocapitalize", value: "none"),
                                    .init(name: "spellcheck", value: "false"), .required
                                )
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Who can reach it" }
                                input(
                                    .type(.text), .name("chatIDs"),
                                    .value(chatIDs.map(String.init).joined(separator: ",")),
                                    .placeholder("Optional, comma-separated")
                                )
                                p(.class("hint")) {
                                    "Leave empty to let Turgai listen to every chat."
                                }
                            }
                        }
                    }
                }
                SetupFooter(
                    step: 5,
                    backHref: "/onboarding/storage",
                    submitFormID: "telegram-form",
                    submitLabel: "Connect Telegram"
                )
            }
        }
    }
}
