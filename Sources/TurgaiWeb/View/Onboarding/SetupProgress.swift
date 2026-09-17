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

struct SetupProgress: HTML, Sendable {
    let step: Int

    var body: some HTML {
        div(
            .class("setup-progress"),
            .init(name: "role", value: "progressbar"),
            .init(name: "aria-label", value: "Step \(step) of 6"),
            .init(name: "aria-valuemin", value: "1"),
            .init(name: "aria-valuemax", value: "6"),
            .init(name: "aria-valuenow", value: String(step))
        ) {
            for segment in 1...6 {
                span(.class("setup-progress-line \(segment <= step ? "is-filled" : "")")) {}
            }
        }
    }
}
