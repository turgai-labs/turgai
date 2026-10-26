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

struct TurgaiExecuteStageFields: HTML, Sendable {
    let step: TurgaiWorkflowStepDraft

    private static let scriptModes: [(String, String)] = [
        ("source", "Write it here"),
        ("file", "Use a file next to this tool"),
    ]

    var body: some HTML {
        div(
            .class("stage-kind-panel"),
            .init(name: "data-stage-panel", value: "execute")
        ) {
            label(.class("form-field")) {
                span(.class("field-label")) { "Script" }
                TurgaiSelect(
                    name: "stageScriptMode",
                    value: step.scriptMode.rawValue,
                    options: Self.scriptModes,
                    dataAttribute: "data-script-mode"
                )
            }
            div(
                .class("script-kind-panel"),
                .init(name: "data-script-panel", value: "source")
            ) {
                label(.class("form-field")) {
                    span(.class("field-label")) { "Script" }
                    textarea(
                        .name("stageScriptSource"),
                        .class("script-editor"),
                        .init(name: "rows", value: "11"),
                        .init(name: "spellcheck", value: "false"),
                        .placeholder("echo \"Hello {{name}}\"")
                    ) {
                        step.scriptSource
                    }
                }
            }
            div(
                .class("script-kind-panel"),
                .init(name: "data-script-panel", value: "file")
            ) {
                label(.class("form-field")) {
                    span(.class("field-label")) { "Script file" }
                    input(
                        .type(.text),
                        .name("stageScriptFile"),
                        .value(step.scriptFile),
                        .placeholder("scripts/weather.sh")
                    )
                    p(.class("hint")) { "Keep the file alongside this tool." }
                }
            }
            label(.class("form-field")) {
                span(.class("field-label")) { "Interpreter" }
                input(
                    .type(.text),
                    .name("stageInterpreter"),
                    .value(step.interpreter),
                    .placeholder("bash, python3, or swift")
                )
                p(.class("hint")) { "Only needed when you write the script here." }
            }
            ScriptOptions(step: step)
        }
    }
}

/// Where a script may write, and what it's given: shown open when any is set.
struct ScriptOptions: HTML, Sendable {
    let step: TurgaiWorkflowStepDraft

    private var isConfigured: Bool {
        [step.writeDirectory, step.arguments, step.environment].contains { (value: String) -> Bool in
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some HTML {
        details(.class("stage-details")) {
            summary(.class("stage-details-summary")) {
                isConfigured
                    ? "Script options (configured)"
                    : "Script options (optional)"
            }
            div(.class("builder-grid builder-grid-two")) {
                label(.class("form-field")) {
                    span(.class("field-label")) { "Writable folder" }
                    input(
                        .type(.text),
                        .name("stageWriteDirectory"),
                        .value(step.writeDirectory),
                        .placeholder("data")
                    )
                    p(.class("hint")) { "Relative to the workspace. Leave empty for the usual location." }
                }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Arguments" }
                    textarea(
                        .name("stageArguments"),
                        .init(name: "rows", value: "3"),
                        .placeholder("--city\n{{city}}")
                    ) {
                        step.arguments
                    }
                }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Environment" }
                    textarea(
                        .name("stageEnvironment"),
                        .init(name: "rows", value: "3"),
                        .placeholder("CITY={{city}}")
                    ) {
                        step.environment
                    }
                }
            }
        }
    }
}
