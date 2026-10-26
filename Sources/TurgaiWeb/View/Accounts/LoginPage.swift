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

struct LoginPage: HTMLDocument, Sendable {
    let error: String?

    init(error: String? = nil) { self.error = error }

    var title: String { "Turgai — Sign in" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            PageShell(
                kind: .setup,
                header: PageHeader(),
                footer: PageFooter {
                    SetupFooterContent(step: nil, submitFormID: "login-form", submitLabel: "Sign in")
                }
            ) {
                section(.class("setup-content setup-content-compact")) {
                    SetupIntro(eyebrow: "Your sky, waiting", title: "Welcome back.", lede: "Pick up where you left off.")
                    div(.class("setup-form-area")) {
                        if let error { p(.class("error")) { error } }
                        form(
                            .method(.post), .action("/login"),
                            .init(name: "id", value: "login-form")
                        ) {
                            CredentialFields(password: .current)
                        }
                        p(.class("hint account-register-prompt")) {
                            "New here? "
                            a(.href("/register"), .class("text-link")) { "Create an account" }
                        }
                    }
                }
            }
        }
    }
}
