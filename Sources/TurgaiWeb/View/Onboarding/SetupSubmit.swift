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

struct SetupSubmit: HTML, Sendable {
    let formID: String
    let label: String

    var body: some HTML {
        button(.type(.submit), .form(formID), .class("setup-arrow setup-arrow-forward setup-submit")) {
            span { label }
            span(.class("arrow-glyph arrow-glyph-long")) { "──────→" }
            span(.class("arrow-glyph arrow-glyph-short")) { "──→" }
        }
    }
}
