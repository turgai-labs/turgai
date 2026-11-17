import Elementary

/// A setup page's heading: a word above, the title, and what the page is for.
struct SetupIntro: HTML, Sendable {
    let eyebrow: String
    let title: String
    let lede: String

    var body: some HTML {
        div(.class("setup-copy")) {
            p(.class("eyebrow")) { eyebrow }
            h1 { title }
            p(.class("lede")) { lede }
        }
    }
}

/// A username and a password: one known already, or one being chosen.
struct CredentialFields: HTML, Sendable {
    enum Password: Sendable {
        case current
        case new
    }

    let password: Password
    /// What the password needs, when it's being chosen.
    var hint: String? = nil

    private var passwordAutocomplete: HTMLAttributeValue.AutoComplete {
        switch password {
        case .current: "current-password"
        case .new: "new-password"
        }
    }

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Username" }
            input(.type(.text), .name("username"), .autocomplete("username"), .required)
        }
        label(.class("form-field")) {
            span(.class("field-label")) { "Password" }
            input(.type(.password), .name("password"), .autocomplete(passwordAutocomplete), .required)
            if let hint { p(.class("hint")) { hint } }
        }
        // A new password is typed twice, so a slip in one isn't what's saved.
        if case .new = password {
            label(.class("form-field")) {
                span(.class("field-label")) { "Password again" }
                input(.type(.password), .name("passwordAgain"), .autocomplete("new-password"), .required)
            }
        }
    }
}
