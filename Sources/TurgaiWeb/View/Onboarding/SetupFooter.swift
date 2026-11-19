import Elementary
import ElementaryHTMX4WS

struct PageFooter<Content: HTML & Sendable>: HTML, Sendable {
    let content: Content
    let behavior: PageFooterBehavior

    init(behavior: PageFooterBehavior = .normal, @HTMLBuilder content: () -> Content) {
        self.content = content()
        self.behavior = behavior
    }

    var body: some HTML {
        footer(.class("page-footer liquid-footer \(behavior.cssClass)")) {
            content
        }
    }
}

extension PageFooterBehavior {
    fileprivate var cssClass: String {
        switch self {
        case .normal:
            ""
        case .sticky:
            "sticky-footer"
        }
    }
}

struct EmptyFooterContent: HTML, Sendable {
    var body: some HTML { span {} }
}

struct SetupFooterContent: HTML, Sendable {
    let step: Int?
    let backHref: String?
    let forwardHref: String?
    let forwardLabel: String?
    let submitFormID: String?
    let submitLabel: String?

    init(
        step: Int?,
        backHref: String? = nil,
        forwardHref: String? = nil,
        forwardLabel: String? = nil,
        submitFormID: String? = nil,
        submitLabel: String? = nil
    ) {
        self.step = step
        self.backHref = backHref
        self.forwardHref = forwardHref
        self.forwardLabel = forwardLabel
        self.submitFormID = submitFormID
        self.submitLabel = submitLabel
    }

    var body: some HTML {
        div(.class("setup-footer")) {
            div(.class("setup-footer-actions")) {
                if let backHref {
                    SetupArrow(href: backHref, label: "Back", direction: .back)
                } else {
                    span(.class("setup-footer-spacer")) {}
                }
                switch (forwardHref, forwardLabel, submitFormID, submitLabel) {
                case (.some(let href), .some(let label), _, _):
                    SetupArrow(href: href, label: label, direction: .forward)
                case (_, _, .some(let formID), .some(let label)):
                    SetupSubmit(formID: formID, label: label)
                default:
                    EmptyFooterContent()
                }
            }
            if let step { SetupProgress(step: step) }
        }
    }
}

struct ChatFooterContent: HTML, Sendable {
    let profileName: String

    var body: some HTML {
        form(.id("chat-composer"), .class("chat-composer-form"), .hx.ws.send) {
            input(.type(.hidden), .name("command"), .value("message"))
            label(.for("chat-message"), .class("chat-composer-label")) {
                "Message \(profileName)"
            }
            div(.class("chat-composer-row")) {
                textarea(
                    .id("chat-message"),
                    .name("text"),
                    .placeholder("Write a message…"),
                    .autocomplete(.off),
                    .init(name: "rows", value: "1"),
                    .required
                ) {}
                ChatComposerButton(stops: false)
            }
        }
        // What the button sends while a reply is worked on: a form of its own, outside the message's.
        form(.id("chat-stop"), .hx.ws.send, .hidden) {
            input(.type(.hidden), .name("command"), .value("stop"))
        }
    }
}
