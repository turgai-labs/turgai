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

struct TurgaiProgramBuilder: HTML, Sendable {
    let executable: String
    let arguments: String
    let environment: String

    private var hasOptions: Bool {
        !arguments.trimmed().isEmpty
            || !environment.trimmed().isEmpty
    }

    var body: some HTML {
        div(
            .class("builder-body-section"),
            .init(name: "data-body-section", value: "process")
        ) {
            p(.class("section-intro")) {
                "Run a program already installed on the machine. Start with its path, then add options only if it needs them."
            }
            label(.class("form-field")) {
                span(.class("field-label")) { "Program" }
                input(
                    .type(.text),
                    .name("processExecutable"),
                    .value(executable),
                    .placeholder("/usr/bin/python3")
                )
                p(.class("hint")) { "No shell is added around it." }
            }
            details(.class("stage-details")) {
                summary(.class("stage-details-summary")) {
                    hasOptions
                        ? "Program options (configured)"
                        : "Program options (optional)"
                }
                div(.class("builder-grid builder-grid-two")) {
                    label(.class("form-field")) {
                        span(.class("field-label")) { "Arguments" }
                        textarea(
                            .name("processArguments"),
                            .init(name: "rows", value: "5"),
                            .placeholder("--city\n{{city}}")
                        ) {
                            arguments
                        }
                    }
                    label(.class("form-field")) {
                        span(.class("field-label")) { "Environment" }
                        textarea(
                            .name("processEnvironment"),
                            .init(name: "rows", value: "5"),
                            .placeholder("CITY={{city}}")
                        ) {
                            environment
                        }
                        p(.class("hint")) { "One NAME=value per line. Optional." }
                    }
                }
            }
        }
    }
}
