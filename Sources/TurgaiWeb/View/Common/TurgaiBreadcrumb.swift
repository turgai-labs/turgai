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

struct TurgaiBreadcrumb: HTML, Sendable {
    let parentTitle: String
    let parentHref: String
    let currentTitle: String

    var body: some HTML {
        nav(
            .class("breadcrumb"),
            .init(name: "aria-label", value: "Breadcrumb")
        ) {
            a(.href(parentHref), .class("breadcrumb-parent")) {
                "← \(parentTitle)"
            }
            span(
                .class("breadcrumb-separator"),
                .init(name: "aria-hidden", value: "true")
            ) {
                "/"
            }
            span(
                .class("breadcrumb-current"),
                .init(name: "aria-current", value: "page")
            ) {
                currentTitle
            }
        }
    }
}
