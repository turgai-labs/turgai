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
    enum Direction: Sendable {
        case back
        case forward
    }

    let href: String
    let label: String
    let direction: Direction

    private var cssClass: String {
        switch direction {
        case .back: "setup-arrow-back"
        case .forward: "setup-arrow-forward"
        }
    }

    var body: some HTML {
        a(.href(href), .class("setup-arrow \(cssClass)")) {
            switch direction {
            case .back:
                span(.class("arrow-glyph arrow-glyph-back")) { "←" }
                span { label }
            case .forward:
                span { label }
                span(.class("arrow-glyph arrow-glyph-long")) { "──────→" }
                span(.class("arrow-glyph arrow-glyph-short")) { "──→" }
            }
        }
    }
}
