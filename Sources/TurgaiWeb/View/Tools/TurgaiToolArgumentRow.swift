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

struct TurgaiToolArgumentRow: HTML, Sendable {
    enum RowKind: Sendable, Equatable {
        case template
        case visible
    }

    let argument: TurgaiToolArgumentDraft
    let kind: RowKind

    var body: some HTML {
        div(
            .class("builder-row argument-row"),
            .init(name: "data-builder-row", value: "argument"),
            kind == .template
                ? .init(name: "data-builder-template", value: "arguments")
                : .init(name: "data-builder-visible", value: "true"),
            kind == .template ? .hidden : .init(name: "data-visible", value: "true")
        ) {
            div(.class("builder-row-fields")) {
                label(.class("form-field")) {
                    span(.class("field-label")) { "Name" }
                    input(
                        .type(.text),
                        .name("argumentName"),
                        .value(argument.name),
                        .placeholder("city")
                    )
                }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Type" }
                    TurgaiSelect(
                        name: "argumentType",
                        value: argument.type.rawValue,
                        options: [
                            ("string", "Text"),
                            ("number", "Number"),
                            ("boolean", "Yes / no"),
                            ("array", "List"),
                            ("object", "Details"),
                        ]
                    )
                }
                label(.class("form-field")) {
                    span(.class("field-label")) { "Required" }
                    TurgaiSelect(
                        name: "argumentRequired",
                        value: argument.required ? "required" : "optional",
                        options: [
                            ("optional", "Optional"),
                            ("required", "Required"),
                        ]
                    )
                }
                label(.class("form-field builder-wide-field")) {
                    span(.class("field-label")) { "Description" }
                    input(
                        .type(.text),
                        .name("argumentDescription"),
                        .value(argument.description),
                        .placeholder("The city to look up")
                    )
                }
            }
            button(
                .type(.button),
                .class("builder-remove"),
                .init(name: "data-remove-row", value: "argument"),
                .init(name: "aria-label", value: "Remove input"),
                .init(name: "title", value: "Remove input")
            ) {
                "×"
            }
        }
    }
}
