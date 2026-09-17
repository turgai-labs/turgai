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

struct TurgaiThinkStageFields: HTML, Sendable {
    let step: TurgaiWorkflowStepDraft

    var body: some HTML {
        div(
            .class("stage-kind-panel"),
            .init(name: "data-stage-panel", value: "think")
        ) {
            label(.class("form-field")) {
                span(.class("field-label")) { "Instruction" }
                textarea(
                    .name("stageInstruction"),
                    .init(name: "rows", value: "6"),
                    .placeholder("Explain the result in one short paragraph.")
                ) {
                    step.instruction
                }
                p(.class("hint")) {
                    "Use this to explain, summarize, or reshape the current result."
                }
            }
        }
    }
}
