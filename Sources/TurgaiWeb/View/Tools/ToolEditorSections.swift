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

/// A tool's name, what it does, and whether running it asks first.
struct ToolNameAndAccess: HTML, Sendable {
    let draft: TurgaiToolDraft

    var body: some HTML {
        section(.class("builder-section")) {
            div(.class("builder-section-intro")) {
                h2 { "Name and access" }
                p(.class("section-intro")) {
                    "Give it a clear name and tell your bot when it belongs in the conversation."
                }
            }
            div(.class("builder-section-content")) {
                div(.class("builder-grid builder-grid-basics")) {
                    label(.class("form-field")) {
                        span(.class("field-label")) { "Name" }
                        input(
                            .type(.text), .name("toolName"), .value(draft.name), .placeholder("weather_brief"),
                            .required)
                    }
                }
                label(.class("form-field builder-wide-field")) {
                    span(.class("field-label")) { "What does it do?" }
                    textarea(
                        .name("toolDescription"),
                        .init(name: "rows", value: "3"),
                        .placeholder("Fetches the weather and gives a short explanation."),
                        .required
                    ) {
                        draft.description
                    }
                }
            }
        }
    }
}

/// The values a tool asks for, with a row to copy for each new one.
struct ToolInputs: HTML, Sendable {
    let arguments: [TurgaiToolArgumentDraft]

    var body: some HTML {
        section(.class("builder-section")) {
            div(.class("builder-section-intro")) {
                h2 { "Inputs (optional)" }
                p(.class("section-intro")) {
                    "Add values the bot should ask for, such as a city or date. Use them as {{name}} later."
                }
            }
            div(.class("builder-section-content")) {
                div(.class("builder-list"), .init(name: "data-empty", value: arguments.isEmpty ? "true" : "false")) {
                    for argument in arguments {
                        TurgaiToolArgumentRow(argument: argument, kind: .visible)
                    }
                    TurgaiToolArgumentRow(argument: TurgaiToolArgumentDraft(), kind: .template)
                }
                button(.type(.button), .class("builder-add"), .init(name: "data-add-row", value: "arguments")) {
                    "+ Add input"
                }
            }
        }
    }
}

/// How a tool works: a workflow, a program, another bot, or a module.
struct ToolAction: HTML, Sendable {
    let draft: TurgaiToolDraft

    var body: some HTML {
        section(.class("builder-section")) {
            div(.class("builder-section-intro")) {
                h2 { "Action" }
                p(.class("section-intro")) {
                    "Choose how this tool acts. Use Workflow when one step needs another step's result."
                }
            }
            div(.class("builder-section-content")) {
                label(.class("form-field builder-wide-field")) {
                    span(.class("field-label")) { "How it works" }
                    TurgaiSelect(
                        name: "bodyKind", value: draft.bodyKind.rawValue, options: kindOptions,
                        dataAttribute: "data-body-kind")
                }
                TurgaiWorkflowBuilder(steps: draft.workflowSteps)
                TurgaiProgramBuilder(
                    executable: draft.processExecutable,
                    arguments: draft.processArguments,
                    environment: draft.processEnvironment
                )
                TurgaiPromptBuilder(instruction: draft.promptInstruction)
                TurgaiWasmBuilder(module: draft.wasmModule)
            }
        }
    }

    /// How a tool can work; running a module is offered only to a tool that already does.
    private var kindOptions: [(String, String)] {
        var options: [(String, String)] = [
            ("workflow", "Workflow — one or more steps"),
            ("process", "Run a program"),
            ("prompt", "Ask another bot"),
        ]
        if draft.bodyKind == .wasm { options.append(("wasm", "Run a module")) }
        return options
    }
}

/// Removes a saved tool, after asking.
struct ToolRemoval: HTML, Sendable {
    let fileName: String

    var body: some HTML {
        form(
            .method(.post),
            .action("/tools/delete"),
            .class("delete-form"),
            .init(name: "onsubmit", value: "return confirm('Remove this tool?');")
        ) {
            input(.type(.hidden), .name("fileName"), .value(fileName))
            button(.type(.submit), .class("text-button text-button-danger")) { "Remove tool" }
        }
    }
}
