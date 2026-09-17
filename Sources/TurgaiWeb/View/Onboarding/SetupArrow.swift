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

struct SetupArrow: HTML, Sendable {
    let href: String
    let label: String
    let isBack: Bool

    var body: some HTML {
        a(.href(href), .class("setup-arrow \(isBack ? "setup-arrow-back" : "setup-arrow-forward")")) {
            if isBack {
                span(.class("arrow-glyph arrow-glyph-back")) { "←" }
                span { label }
            } else {
                span { label }
                span(.class("arrow-glyph arrow-glyph-long")) { "──────→" }
                span(.class("arrow-glyph arrow-glyph-short")) { "──→" }
            }
        }
    }
}
