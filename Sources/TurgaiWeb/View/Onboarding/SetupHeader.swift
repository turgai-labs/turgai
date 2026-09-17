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

struct SetupHeader: HTML, Sendable {
    var body: some HTML {
        header(.class("setup-header")) {
            a(.href("/"), .class("wordmark")) {
                img(.src("/skylark.svg"), .alt(""), .class("wordmark-logo"))
                span(.class("wordmark-text")) { "turgai" }
            }
        }
    }
}
