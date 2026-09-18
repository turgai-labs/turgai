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

struct TurgaiWorkflowBuilder: HTML, Sendable {
    let steps: [TurgaiWorkflowStepDraft]

    var body: some HTML {
        div(
            .class("builder-body-section"),
            .init(name: "data-body-section", value: "workflow")
        ) {
            p(.class("builder-hint")) {
                "Runs from top to bottom. Start with one step, then add another when it needs the first step's result."
            }
            div(
                .class("builder-list"),
                .init(name: "data-stage-list", value: "")
            ) {
                for (index, step) in steps.enumerated() {
                    TurgaiWorkflowStageRow(step: step, number: index + 1, kind: .visible)
                }
                TurgaiWorkflowStageRow(
                    step: TurgaiWorkflowStepDraft(),
                    number: 1,
                    kind: .template
                )
            }
            button(
                .type(.button),
                .class("builder-add"),
                .init(name: "data-add-row", value: "stages"),
                .init(name: "data-empty-add", value: ""),
                steps.isEmpty ? .init(name: "data-visible", value: "true") : .hidden
            ) {
                "+ Add step"
            }
        }
    }
}
