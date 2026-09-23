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

struct StoragePage: HTMLDocument, Sendable {
    let values: StorageFormValues
    let defaultFileDirectory: URL
    let error: String?

    init(
        storage: TurgaiStorageConfiguration?,
        defaultFileDirectory: URL,
        error: String? = nil
    ) {
        switch storage {
        case .file(let directory):
            self.values = StorageFormValues(
                backend: .file,
                fileURL: directory.absoluteString,
                postgresURL: "postgres://localhost:5432/turgai",
                postgresUsername: ""
            )
        case .postgres(let url, let username):
            self.values = StorageFormValues(
                backend: .postgres,
                fileURL: defaultFileDirectory.absoluteString,
                postgresURL: url.absoluteString,
                postgresUsername: username
            )
        case nil:
            self.values = StorageFormValues(
                backend: .file,
                fileURL: defaultFileDirectory.absoluteString,
                postgresURL: "postgres://localhost:5432/turgai",
                postgresUsername: ""
            )
        }
        self.defaultFileDirectory = defaultFileDirectory
        self.error = error
    }

    init(
        values: StorageFormValues,
        defaultFileDirectory: URL,
        error: String
    ) {
        self.values = values
        self.defaultFileDirectory = defaultFileDirectory
        self.error = error
    }

    var title: String { "Turgai — Storage" }
    var head: some HTML { TurgaiHead() }
    var body: some HTML {
        main(.class("setup-page")) {
            PageShell(
                kind: .setup,
                header: PageHeader(),
                footer: PageFooter {
                    SetupFooterContent(
                        step: 4,
                        backHref: "/onboarding/model",
                        submitFormID: "storage-form",
                        submitLabel: "Save this choice"
                    )
                },
            ) {
                section(.class("setup-content")) {
                    div(.class("setup-copy")) {
                        p(.class("eyebrow")) { "A home for memory" }
                        h1 { "Give memory a home." }
                        p(.class("lede")) {
                            "Choose where Turgai keeps its memory and history. The local option is the simplest place to begin."
                        }
                        div(.class("setup-form-area")) {
                            if let error { p(.class("error")) { error } }
                            form(
                                .method(.post), .action("/onboarding/storage"),
                                .init(name: "id", value: "storage-form")
                            ) {
                                label(.class("form-field")) {
                                    span(.class("field-label")) { "Memory home" }
                                    select(
                                        .name("backend"),
                                        .id("turgai-storage-backend"),
                                        .init(
                                            name: "onchange",
                                            value:
                                                "document.querySelectorAll('[data-storage-panel]').forEach((panel) => panel.hidden = panel.dataset.storagePanel !== this.value)"
                                        )
                                    ) {
                                        switch values.backend {
                                        case .file:
                                            option(.value("file"), .selected) { "File store" }
                                        case .postgres:
                                            option(.value("file")) { "File store" }
                                        }
                                        switch values.backend {
                                        case .postgres:
                                            option(.value("postgres"), .selected) { "PostgreSQL" }
                                        case .file:
                                            option(.value("postgres")) { "PostgreSQL" }
                                        }
                                    }
                                }
                                div(
                                    .class("storage-panel"),
                                    .init(name: "data-storage-panel", value: "file"),
                                    values.backend == .file ? .init(name: "data-active", value: "true") : .hidden
                                ) {
                                    label(.class("form-field")) {
                                        span(.class("field-label")) { "Local folder" }
                                        input(
                                            .type(.url), .name("fileURL"), .value(values.fileURL),
                                            .placeholder("file:///path/to/turgai")
                                        )
                                        p(.class("hint")) {
                                            "Default: \(defaultFileDirectory.absoluteString)"
                                        }
                                    }
                                }
                                div(
                                    .class("storage-panel"),
                                    .init(name: "data-storage-panel", value: "postgres"),
                                    values.backend == .postgres ? .init(name: "data-active", value: "true") : .hidden
                                ) {
                                    label(.class("form-field")) {
                                        span(.class("field-label")) { "PostgreSQL address" }
                                        input(
                                            .type(.url), .name("postgresURL"), .value(values.postgresURL),
                                            .placeholder("postgres://localhost:5432/turgai")
                                        )
                                    }
                                    label(.class("form-field")) {
                                        span(.class("field-label")) { "Username" }
                                        input(
                                            .type(.text), .name("postgresUsername"),
                                            .value(values.postgresUsername), .autocomplete("username")
                                        )
                                    }
                                    label(.class("form-field")) {
                                        span(.class("field-label")) { "Password" }
                                        input(
                                            .type(.password), .name("postgresPassword"),
                                            .autocomplete("new-password")
                                        )
                                        p(.class("hint")) {
                                            "Kept separately from the connection details."
                                        }
                                    }
                                }
                            }
                            p(.class("hint storage-restart-note")) {
                                "Turgai will start using this home when setup is complete."
                            }
                        }
                    }
                }
            }
        }
    }
}
