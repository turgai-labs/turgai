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
    /// Turgai's directory, where its own database is.
    let directory: URL
    let error: String?

    init(
        storage: TurgaiStorageConfiguration?,
        directory: URL,
        error: String? = nil
    ) {
        switch storage {
        case .postgres(let url, let username):
            self.values = StorageFormValues(
                backend: .postgres,
                postgresURL: url.absoluteString,
                postgresUsername: username
            )
        case .local, nil:
            self.values = StorageFormValues(
                backend: .local,
                postgresURL: "postgres://localhost:5432/turgai",
                postgresUsername: ""
            )
        }
        self.directory = directory
        self.error = error
    }

    init(
        values: StorageFormValues,
        directory: URL,
        error: String
    ) {
        self.values = values
        self.directory = directory
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
                StorageContent(values: values, directory: directory, error: error)
            }
        }
    }
}

/// The storage step's copy and its form, with what went wrong, when something did.
private struct StorageContent: HTML, Sendable {
    let values: StorageFormValues
    let directory: URL
    let error: String?

    var body: some HTML {
        section(.class("setup-content")) {
            div(.class("setup-copy")) {
                p(.class("eyebrow")) { "A home for memory" }
                h1 { "Give memory a home." }
                p(.class("lede")) {
                    "Choose where Turgai keeps its memory and history. The local option is the simplest place to begin."
                }
                div(.class("setup-form-area")) {
                    if let error { p(.class("error")) { error } }
                    StorageForm(values: values, directory: directory)
                    p(.class("hint storage-restart-note")) {
                        "Turgai will start using this home when setup is complete."
                    }
                }
            }
        }
    }
}

/// Where memory is kept, and how to reach it.
struct StorageForm: HTML, Sendable {
    let values: StorageFormValues
    let directory: URL

    var body: some HTML {
        form(.method(.post), .action("/onboarding/storage"), .init(name: "id", value: "storage-form")) {
            StorageBackendPicker(backend: values.backend)
            LocalStoragePanel(directory: directory, isActive: values.backend == .local)
            PostgresStoragePanel(values: values, isActive: values.backend == .postgres)
        }
    }
}

/// Where memory is kept: in a database file on this machine, or in PostgreSQL. Choosing one shows
/// its panel.
struct StorageBackendPicker: HTML, Sendable {
    let backend: StorageBackend

    private static let showsChosenPanel =
        "document.querySelectorAll('[data-storage-panel]').forEach((panel) => panel.hidden = panel.dataset.storagePanel !== this.value)"

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Memory home" }
            select(
                .name("backend"), .id("turgai-storage-backend"),
                .init(name: "onchange", value: Self.showsChosenPanel)
            ) {
                if backend == .local {
                    option(.value("local"), .selected) { "This machine" }
                    option(.value("postgres")) { "PostgreSQL" }
                } else {
                    option(.value("local")) { "This machine" }
                    option(.value("postgres"), .selected) { "PostgreSQL" }
                }
            }
        }
    }
}

/// A storage panel's state: shown when its backend is the chosen one, hidden otherwise.
private func storagePanelState(isActive: Bool) -> HTMLAttribute<HTMLTag.div> {
    isActive ? .init(name: "data-active", value: "true") : .hidden
}

/// Memory kept on this machine, in Turgai's own database.
struct LocalStoragePanel: HTML, Sendable {
    let directory: URL
    let isActive: Bool

    var body: some HTML {
        div(
            .class("storage-panel"), .init(name: "data-storage-panel", value: "local"),
            storagePanelState(isActive: isActive)
        ) {
            p(.class("hint")) {
                "Kept in Turgai's own database, \(TurgaiPersistence.databaseName), in \(directory.path)."
            }
        }
    }
}

/// The PostgreSQL database memory is kept in, and how to sign in to it.
struct PostgresStoragePanel: HTML, Sendable {
    let values: StorageFormValues
    let isActive: Bool

    var body: some HTML {
        div(
            .class("storage-panel"), .init(name: "data-storage-panel", value: "postgres"),
            storagePanelState(isActive: isActive)
        ) {
            label(.class("form-field")) {
                span(.class("field-label")) { "PostgreSQL address" }
                input(
                    .type(.url), .name("postgresURL"), .value(values.postgresURL),
                    .placeholder("postgres://localhost:5432/turgai"))
            }
            label(.class("form-field")) {
                span(.class("field-label")) { "Username" }
                input(
                    .type(.text), .name("postgresUsername"), .value(values.postgresUsername),
                    .autocomplete("username"))
            }
            p(.class("hint")) {
                "Its password is PostgreSQL's own: Turgai reads PGPASSWORD, or ~/.pgpass, where it runs."
            }
        }
    }
}
