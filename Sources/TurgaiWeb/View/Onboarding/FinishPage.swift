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

struct FinishPage: HTMLDocument, Sendable {
    var title: String { "Turgai — Ready" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            PageShell(
                kind: .setup,
                header: PageHeader(),
                footer: PageFooter {
                    SetupFooterContent(
                        step: 5,
                        backHref: "/onboarding/storage",
                        submitFormID: "finish-form",
                        submitLabel: "Start Turgai"
                    )
                }
            ) {
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "Ready when you are" }
                        h1 { "Your Turgai is ready." }
                        p(.class("lede")) {
                            "Everything is in place. Start a conversation, then shape it as you go."
                        }
                    }
                    div(.class("setup-form-area setup-welcome-area")) {
                        form(
                            .method(.post), .action("/onboarding/finish"),
                            .init(name: "id", value: "finish-form")
                        ) {}
                    }
                }
            }
        }
    }
}
