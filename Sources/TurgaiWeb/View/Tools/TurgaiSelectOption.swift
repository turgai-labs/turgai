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
    enum Selection: Sendable {
        case selected
        case unselected
    }

    let value: String
    let label: String
    let selection: Selection

    var body: some HTML {
        switch selection {
        case .selected:
            option(.value(value), .selected) { label }
        case .unselected:
            option(.value(value)) { label }
        }
    }
}
