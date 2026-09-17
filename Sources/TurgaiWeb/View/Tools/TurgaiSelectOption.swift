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

struct TurgaiSelectOption: HTML, Sendable {
    let value: String
    let label: String
    let selected: Bool

    var body: some HTML {
        if selected {
            option(.value(value), .selected) { label }
        } else {
            option(.value(value)) { label }
        }
    }
}
