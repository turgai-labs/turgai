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

struct TurgaiToolRow: HTML, Sendable {
    enum Access: Sendable {
        case view
        case edit
    }

    let document: UserToolDocument
    let access: Access

    private var href: String { "/tools/\(document.fileName)" }

    private var kind: String {
        guard let tool = document.tool else { return "unavailable" }
        switch tool.body {
        case .workflow(let workflow):
            return "\(workflow.steps.count) steps"
        case .process:
            return "program"
        case .wasm:
            return "module"
        case .prompt:
            return "prompt"
        }
    }

    var body: some HTML {
        div(.class("tool-row \(document.isValid ? "" : "tool-row-invalid")")) {
            div(.class("tool-row-main")) {
                if let tool = document.tool {
                    a(.href(href), .class("tool-name")) { tool.name }
                    p(.class("tool-description")) { tool.description }
                } else {
                    a(.href(href), .class("tool-name")) { "Tool needs attention" }
                    p(.class("tool-description tool-issue")) {
                        "This tool could not be loaded. Open it to repair or remove it."
                    }
                }
            }
            div(.class("tool-row-meta")) {
                span(.class("tool-meta-label")) { "Kind" }
                span { kind }
            }
            div(.class("tool-row-meta")) {
                span(.class("tool-meta-label")) { "Approval" }
                span {
                    if let tool = document.tool {
                        tool.approval.rawValue == "always" ? "asks first" : "runs directly"
                    } else {
                        "unavailable"
                    }
                }
            }
            a(.href(href), .class("tool-row-action")) {
                switch access {
                case .view: "View →"
                case .edit: document.isValid ? "Edit →" : "Review →"
                }
            }
        }
    }
}
