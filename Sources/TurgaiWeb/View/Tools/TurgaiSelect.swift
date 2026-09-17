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

struct TurgaiSelect: HTML, Sendable {
    let name: String
    let value: String
    let options: [(String, String)]
    let dataAttribute: String?

    init(
        name: String,
        value: String,
        options: [(String, String)],
        dataAttribute: String? = nil
    ) {
        self.name = name
        self.value = value
        self.options = options
        self.dataAttribute = dataAttribute
    }

    var body: some HTML {
        if let dataAttribute {
            select(.name(name), .init(name: dataAttribute, value: "")) {
                TurgaiSelectOptions(options: options, value: value)
            }
        } else {
            select(.name(name)) {
                TurgaiSelectOptions(options: options, value: value)
            }
        }
    }
}
