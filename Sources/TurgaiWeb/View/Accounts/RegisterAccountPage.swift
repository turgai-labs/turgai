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
            div(.class("setup-shell")) {
                SetupHeader()
                section(.class("setup-content setup-content-compact")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "Join this Turgai" }
                        h1 { "Make room for another voice." }
                        p(.class("lede")) {
                            "Create an account to use this Turgai installation. An administrator will approve it before you can sign in."
                        }
                    }
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
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "Username" }
                                    input(.type(.text), .name("username"), .autocomplete("username"), .required)
                                }
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "Password" }
                                    input(.type(.password), .name("password"), .autocomplete("new-password"), .required)
                                    p(.class("hint")) { "Use at least 12 characters." }
                                }
                            }
                        }
                    }
                }
                if success == nil {
                    SetupFooter(
                        step: nil,
                        backHref: "/login",
                        submitFormID: "account-register-form",
                        submitLabel: "Create account"
                    )
                }
            }
        }
    }
}
