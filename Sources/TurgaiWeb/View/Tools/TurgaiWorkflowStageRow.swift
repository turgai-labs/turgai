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

struct TurgaiWorkflowStageRow: HTML, Sendable {
    enum RowKind: Sendable, Equatable {
        case template
        case visible
    }

    let step: TurgaiWorkflowStepDraft
    let number: Int
    let kind: RowKind

    private var hasStepOptions: Bool {
        !step.saveAs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || step.permission != .inherit
            || !step.inputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some HTML {
        div(
            .class("builder-row workflow-stage-row"),
            .init(name: "data-builder-row", value: "stage"),
            .init(name: "data-stage-row", value: ""),
            kind == .template
                ? .init(name: "data-builder-template", value: "stages")
                : .init(name: "data-builder-visible", value: "true"),
            kind == .template ? .hidden : .init(name: "data-visible", value: "true")
        ) {
            div(.class("stage-heading")) {
                span(.class("stage-number"), .init(name: "data-stage-number", value: "")) {
                    String(number)
                }
                TurgaiSelect(
                    name: "stageKind",
                    value: step.kind.rawValue,
                    options: [
                        ("fetch", "Get information"),
                        ("execute", "Run a script"),
                        ("think", "Explain a result"),
                    ],
                    dataAttribute: "data-stage-kind"
                )
                button(
                    .type(.button),
                    .class("builder-remove"),
                    .init(name: "data-remove-row", value: "stage"),
                    .init(name: "aria-label", value: "Remove step"),
                    .init(name: "title", value: "Remove step")
                ) {
                    "×"
                }
            }
            div(.class("stage-primary-fields")) {
                label(.class("form-field")) {
                    span(.class("field-label")) { "Step name" }
                    if case .template = kind {
                        input(
                            .type(.text),
                            .name("stageID"),
                            .value(step.id),
                            .placeholder("forecast"),
                            .init(name: "data-required", value: "true")
                        )
                    } else {
                        input(
                            .type(.text),
                            .name("stageID"),
                            .value(step.id),
                            .placeholder("forecast"),
                            .required
                        )
                    }
                    p(.class("hint")) { "A short name for what this step returns." }
                }
            }
            TurgaiFetchStageFields(step: step)
            TurgaiExecuteStageFields(step: step)
            TurgaiThinkStageFields(step: step)
            details(.class("stage-details")) {
                summary(.class("stage-details-summary")) {
                    hasStepOptions ? "Optional step settings (configured)" : "Optional step settings"
                }
                div(.class("builder-grid builder-grid-two")) {
                    label(.class("form-field")) {
                        span(.class("field-label")) { "Output name" }
                        input(
                            .type(.text),
                            .name("stageSaveAs"),
                            .value(step.saveAs),
                            .placeholder("forecast")
                        )
                        p(.class("hint")) { "Give this result another name if a later step needs it." }
                    }
                    label(.class("form-field")) {
                        span(.class("field-label")) { "Permission" }
                        TurgaiSelect(
                            name: "stagePermission",
                            value: step.permission.rawValue,
                            options: [
                                ("inherit", "Use tool access"),
                                ("allowed", "Allow this step"),
                                ("denied", "Block this step"),
                            ]
                        )
                    }
                }
                label(.class("form-field builder-wide-field")) {
                    span(.class("field-label")) { "Earlier results" }
                    textarea(
                        .name("stageInputs"),
                        .init(name: "rows", value: "2"),
                        .placeholder("forecast=step-1")
                    ) {
                        step.inputs
                    }
                    p(.class("hint")) { "Pass saved results as name=value, one per line." }
                }
            }
            div(.class("stage-row-footer")) {
                button(
                    .type(.button),
                    .class("builder-add"),
                    .init(name: "data-add-after", value: "stages"),
                    .init(name: "aria-label", value: "Add step after this step"),
                    .init(name: "title", value: "Add step after this step")
                ) {
                    "+ Add step"
                }
            }
        }
    }
}
