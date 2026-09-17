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

struct TurgaiWasmBuilder: HTML, Sendable {
    let module: String

    var body: some HTML {
        div(
            .class("builder-body-section"),
            .init(name: "data-body-section", value: "wasm")
        ) {
            p(.class("section-intro")) {
                "Run a prebuilt WebAssembly module kept next to this tool."
            }
            label(.class("form-field")) {
                span(.class("field-label")) { "Module file" }
                input(
                    .type(.text),
                    .name("wasmModule"),
                    .value(module),
                    .placeholder("modules/transform.wasm")
                )
                p(.class("hint")) { "Use a relative path ending in .wasm." }
            }
        }
    }
}
