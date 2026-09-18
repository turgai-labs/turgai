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

struct TurgaiSelectOptions: HTML, Sendable {
    let options: [(String, String)]
    let value: String

    var body: some HTML {
        for optionValue in options {
            TurgaiSelectOption(
                value: optionValue.0,
                label: optionValue.1,
                selection: optionValue.0 == value ? .selected : .unselected
            )
        }
    }
}
