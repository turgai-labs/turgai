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

struct TurgaiFetchStageFields: HTML, Sendable {
    let step: TurgaiWorkflowStepDraft

    private var hasConnectionOptions: Bool {
        step.method.uppercased() != "GET"
            || !step.allowedHosts.trimmed().isEmpty
            || !step.headers.trimmed().isEmpty
            || !step.body.trimmed().isEmpty
    }

    var body: some HTML {
        div(
            .class("stage-kind-panel"),
            .init(name: "data-stage-panel", value: "fetch")
        ) {
            label(.class("form-field")) {
                span(.class("field-label")) { "Web address" }
                input(
                    .type(.url),
                    .name("stageURL"),
                    .value(step.url),
                    .placeholder("https://api.example.com/weather?city={{city}}")
                )
                p(.class("hint")) { "Use {{input}} to bring in a value from the Inputs section." }
            }
            details(.class("stage-details")) {
                summary(.class("stage-details-summary")) {
                    hasConnectionOptions
                        ? "Connection options (configured)"
                        : "Connection options (optional)"
                }
                div(.class("builder-grid builder-grid-two")) {
                    label(.class("form-field")) {
                        span(.class("field-label")) { "Method" }
                        TurgaiSelect(
                            name: "stageMethod",
                            value: step.method,
                            options: [
                                ("GET", "GET"),
                                ("POST", "POST"),
                                ("PUT", "PUT"),
                                ("PATCH", "PATCH"),
                                ("DELETE", "DELETE"),
                            ]
                        )
                    }
                    label(.class("form-field")) {
                        span(.class("field-label")) { "Allowed websites" }
                        input(
                            .type(.text),
                            .name("stageAllowedHosts"),
                            .value(step.allowedHosts),
                            .placeholder("api.example.com, weather.example.com")
                        )
                        p(.class("hint")) { "Leave empty to use the bot's usual network access." }
                    }
                    label(.class("form-field")) {
                        span(.class("field-label")) { "Headers" }
                        textarea(
                            .name("stageHeaders"),
                            .init(name: "rows", value: "2"),
                            .placeholder("Authorization: Bearer {{token}}")
                        ) {
                            step.headers
                        }
                    }
                }
                label(.class("form-field builder-wide-field")) {
                    span(.class("field-label")) { "Request body" }
                    textarea(
                        .name("stageBody"),
                        .init(name: "rows", value: "3"),
                        .placeholder("Optional request body")
                    ) {
                        step.body
                    }
                }
            }
        }
    }
}
