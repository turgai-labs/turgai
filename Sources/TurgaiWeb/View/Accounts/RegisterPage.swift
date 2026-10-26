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

struct RegisterPage: HTMLDocument, Sendable {
    let challenge: String
    let error: String?

    init(challenge: String, error: String? = nil) {
        self.challenge = challenge
        self.error = error
    }
    var title: String { "Turgai — Create administrator" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            PageShell(
                kind: .setup,
                header: PageHeader(),
                footer: PageFooter {
                    SetupFooterContent(
                        step: 2,
                        backHref: "/onboarding",
                        submitFormID: "register-form",
                        submitLabel: "Create my account"
                    )
                },
            ) {
                section(.class("setup-content")) {
                    SetupIntro(
                        eyebrow: "Make it yours", title: "Keep the keys.",
                        lede: "Create the account that keeps this Turgai installation in your hands.")
                    div(.class("setup-form-area")) {
                        if let error { p(.class("error")) { error } }
                        form(
                            .method(.post), .action("/onboarding/register"),
                            .init(name: "id", value: "register-form")
                        ) {
                            input(.type(.hidden), .name("challenge"), .value(challenge))
                            CredentialFields(password: .new)
                        }
                    }
                }
            }
        }
    }
}
