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
            div(.class("setup-shell")) {
                SetupHeader()
                section(.class("setup-content setup-content-compact")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "Your sky, waiting" }
                        h1 { "Welcome back." }
                        p(.class("lede")) { "Pick up where you left off." }
                    }
                    div(.class("setup-form-area")) {
                        if let error { p(.class("error")) { error } }
                        form(
                            .method(.post), .action("/login"),
                            .init(name: "id", value: "login-form")
                        ) {
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Username" }
                                input(.type(.text), .name("username"), .autocomplete("username"), .required)
                            }
                            label(.class("form-field")) {
                                span(.class("field-label")) { "Password" }
                                input(.type(.password), .name("password"), .autocomplete("current-password"), .required)
                            }
                        }
                        p(.class("hint account-register-prompt")) {
                            "New here? "
                            a(.href("/register"), .class("text-link")) { "Create an account" }
                        }
                    }
                }
                SetupFooter(step: nil, submitFormID: "login-form", submitLabel: "Sign in")
            }
        }
    }
}
