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

struct TurgaiPromptBuilder: HTML, Sendable {
    let instruction: String

    var body: some HTML {
        div(
            .class("builder-body-section"),
            .init(name: "data-body-section", value: "prompt")
        ) {
            p(.class("section-intro")) {
                "Ask another bot to take on one focused piece of thinking and bring back its answer."
            }
            label(.class("form-field")) {
                span(.class("field-label")) { "Instruction" }
                textarea(
                    .name("promptInstruction"),
                    .init(name: "rows", value: "10"),
                    .placeholder("Summarize the information for {{city}}.")
                ) {
                    instruction
                }
                p(.class("hint")) {
                    "Use {{input}} to include an input from above."
                }
            }
        }
    }
}
