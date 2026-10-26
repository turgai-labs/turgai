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

struct RegisterAccountPage: HTMLDocument, Sendable {
    let error: String?
    let success: String?

    init(error: String? = nil, success: String? = nil) {
        self.error = error
        self.success = success
    }

    var title: String { "Turgai — Create account" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            PageShell(
                kind: .setup,
                header: PageHeader(),
                footer: PageFooter {
                    SetupFooterContent(
                        step: nil,
                        backHref: "/login",
                        submitFormID: "account-register-form",
                        submitLabel: "Create account"
                    )
                },
            ) {
                section(.class("setup-content setup-content-compact")) {
                    SetupIntro(
                        eyebrow: "Join this Turgai", title: "Make room for another voice.",
                        lede:
                            "Create an account to chat with this Turgai installation. You can sign in immediately; an administrator can grant dashboard access later."
                    )
                    div(.class("setup-form-area")) {
                        if let error { p(.class("error")) { error } }
                        if let success {
                            p(.class("success")) { success }
                            a(.href("/login"), .class("text-link")) { "Back to sign in →" }
                        } else {
                            form(
                                .method(.post), .action("/register"),
                                .init(name: "id", value: "account-register-form")
                            ) {
                                CredentialFields(password: .new, hint: "Use at least 12 characters.")
                            }
                        }
                    }
                }
            }
        }
    }
}
