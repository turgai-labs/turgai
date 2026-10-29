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
import TurgaiDomain

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

    /// A template row is hidden, and copied for each new step; a visible one is a step.
    private var rowAttributes: [HTMLAttribute<HTMLTag.div>] {
        let row: [HTMLAttribute<HTMLTag.div>] = [
            .class("builder-row workflow-stage-row"),
            .init(name: "data-builder-row", value: "stage"),
            .init(name: "data-stage-row", value: ""),
        ]
        switch kind {
        case .template: return row + [.init(name: "data-builder-template", value: "stages"), .hidden]
        case .visible:
            return row + [.init(name: "data-builder-visible", value: "true"), .init(name: "data-visible", value: "true")]
        }
    }

    var body: some HTML {
        div(attributes: rowAttributes) {
            StageHeading(step: step, number: number)
            div(.class("stage-primary-fields")) {
                StepNameField(id: step.id, isTemplate: kind == .template)
            }
            TurgaiFetchStageFields(step: step)
            TurgaiExecuteStageFields(step: step)
            TurgaiThinkStageFields(step: step)
            StepOptions(step: step)
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

/// A step's number, what kind it is, and removing it.
struct StageHeading: HTML, Sendable {
    let step: TurgaiWorkflowStepDraft
    let number: Int

    private static let kinds: [(String, String)] = [
        ("fetch", "Get information"),
        ("execute", "Run a script"),
        ("think", "Explain a result"),
    ]

    var body: some HTML {
        div(.class("stage-heading")) {
            span(.class("stage-number"), .init(name: "data-stage-number", value: "")) { String(number) }
            TurgaiSelect(
                name: "stageKind", value: step.kind.rawValue, options: Self.kinds, dataAttribute: "data-stage-kind")
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
    }
}

/// A step's name: required once the row is a step, not while it's the template.
struct StepNameField: HTML, Sendable {
    let id: String
    let isTemplate: Bool

    private var required: HTMLAttribute<HTMLTag.input> {
        isTemplate ? .init(name: "data-required", value: "true") : .required
    }

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Step name" }
            input(.type(.text), .name("stageID"), .value(id), .placeholder("forecast"), required)
            p(.class("hint")) { "A short name for what this step returns." }
        }
    }
}

/// What a step's result is called, whether it may run, and what earlier results it's given.
struct StepOptions: HTML, Sendable {
    let step: TurgaiWorkflowStepDraft

    private static let permissions: [(String, String)] = [
        ("inherit", "Use tool access"),
        ("allowed", "Allow this step"),
        ("denied", "Block this step"),
    ]

    private var isConfigured: Bool {
        !step.saveAs.trimmed().isEmpty
            || step.permission != .inherit
            || !step.inputs.trimmed().isEmpty
    }

    var body: some HTML {
        details(.class("stage-details")) {
            summary(.class("stage-details-summary")) {
                isConfigured ? "Optional step settings (configured)" : "Optional step settings"
            }
            div(.class("builder-grid builder-grid-two")) {
                label(.class("form-field")) {
                    span(.class("field-label")) { "Output name" }
                    input(.type(.text), .name("stageSaveAs"), .value(step.saveAs), .placeholder("forecast"))
                    p(.class("hint")) { "Give this result another name if a later step needs it." }
                }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Permission" }
                    TurgaiSelect(name: "stagePermission", value: step.permission.rawValue, options: Self.permissions)
                }
            }
            label(.class("form-field builder-wide-field")) {
                span(.class("field-label")) { "Earlier results" }
                textarea(.name("stageInputs"), .init(name: "rows", value: "2"), .placeholder("forecast=step-1")) {
                    step.inputs
                }
                p(.class("hint")) { "Pass saved results as name=value, one per line." }
            }
        }
    }
}
