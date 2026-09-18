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

struct TurgaiToolEditorPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let draft: TurgaiToolDraft
    let issue: UserToolLoadIssue?
    let error: String?

    init(
        user: AuthenticatedUser,
        draft: TurgaiToolDraft,
        issue: UserToolLoadIssue? = nil,
        error: String? = nil
    ) {
        self.user = user
        self.draft = draft
        self.issue = issue
        self.error = error
    }

    private var draftLabel: String {
        switch draft.kind {
        case .new: "New tool"
        case .existing: "Edit tool"
        }
    }

    private var draftKindValue: String {
        switch draft.kind {
        case .new: "true"
        case .existing: "false"
        }
    }

    var title: String { "Turgai — \(draftLabel)" }
    var head: some HTML { TurgaiHead() }

    private var heading: String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty else { return name }
        switch draft.kind {
        case .new: return "Build a tool"
        case .existing: return "Edit tool"
        }
    }

    var body: some HTML {
        main(.class("app-page")) {
            div(.class("app-shell tool-editor-shell")) {
                AppHeader(user: user, section: .tools)
                section(.class("page-intro detail-page-intro")) {
                    div {
                        TurgaiBreadcrumb(
                            parentTitle: "Tools",
                            parentHref: "/tools",
                            currentTitle: draftLabel
                        )
                        h1 { heading }
                        p(.class("lede")) {
                            "Give it a clear purpose, choose how it works, and add steps only when they earn their place."
                        }
                    }
                }
                if let error {
                    p(.class("error page-error")) { error }
                } else if issue != nil {
                    p(.class("error page-error")) {
                        "This tool needs attention. Repair its setup below or remove it."
                    }
                }
                div(.class("tool-editor-layout")) {
                    section(.class("tool-editor-main")) {
                        p(.class("detail-note tool-editor-note")) {
                            "Changes take effect the next time this bot is activated. Conversations already running keep their current agent."
                        }
                        form(
                            .method(.post),
                            .action("/tools/save"),
                            .class("tool-editor-form"),
                            .init(name: "data-tool-editor", value: "")
                        ) {
                            input(.type(.hidden), .name("fileName"), .value(draft.fileName))
                            input(.type(.hidden), .name("isNew"), .value(draftKindValue))

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
                                                .type(.text),
                                                .name("toolName"),
                                                .value(draft.name),
                                                .placeholder("weather_brief"),
                                                .required
                                            )
                                        }
                                        label(.class("form-field")) {
                                            span(.class("field-label")) { "Ask before running" }
                                            TurgaiSelect(
                                                name: "approval",
                                                value: draft.approval,
                                                options: [
                                                    ("always", "Ask me each time"),
                                                    ("never", "Run without asking"),
                                                ]
                                            )
                                            p(.class("hint")) {
                                                "Ask first when a tool can change files or reach outside this installation."
                                            }
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

                            section(.class("builder-section")) {
                                div(.class("builder-section-intro")) {
                                    h2 { "Inputs (optional)" }
                                    p(.class("section-intro")) {
                                        "Add values the bot should ask for, such as a city or date. Use them as {{name}} later."
                                    }
                                }
                                div(.class("builder-section-content")) {
                                    div(
                                        .class("builder-list"),
                                        .init(
                                            name: "data-empty",
                                            value: draft.arguments.isEmpty ? "true" : "false"
                                        )
                                    ) {
                                        for argument in draft.arguments {
                                            TurgaiToolArgumentRow(argument: argument, kind: .visible)
                                        }
                                        TurgaiToolArgumentRow(
                                            argument: TurgaiToolArgumentDraft(),
                                            kind: .template
                                        )
                                    }
                                    button(
                                        .type(.button),
                                        .class("builder-add"),
                                        .init(name: "data-add-row", value: "arguments")
                                    ) {
                                        "+ Add input"
                                    }
                                }
                            }

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
                                            name: "bodyKind",
                                            value: draft.bodyKind.rawValue,
                                            options: [
                                                ("workflow", "Workflow — one or more steps"),
                                                ("process", "Run a program"),
                                                ("prompt", "Ask another bot"),
                                            ]
                                                + (draft.bodyKind == .wasm
                                                    ? [("wasm", "Run a module")]
                                                    : []),
                                            dataAttribute: "data-body-kind"
                                        )
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

                            div(.class("form-actions")) {
                                button(.type(.submit), .class("button button-accent")) {
                                    "Save tool"
                                }
                                a(.href("/tools"), .class("button button-secondary")) {
                                    "Cancel"
                                }
                            }
                        }
                        if case .existing = draft.kind {
                            form(
                                .method(.post),
                                .action("/tools/delete"),
                                .class("delete-form"),
                                .init(
                                    name: "onsubmit",
                                    value: "return confirm('Remove this tool?');"
                                )
                            ) {
                                input(.type(.hidden), .name("fileName"), .value(draft.fileName))
                                button(.type(.submit), .class("text-button text-button-danger")) {
                                    "Remove tool"
                                }
                            }
                        }
                    }
                    aside(.class("tool-editor-aside")) {
                        h2 { "Quick guide" }
                        p(.class("section-intro")) {
                            "Start with Get information or Run a script. Reach for Workflow when one result needs to travel into the next step."
                        }
                        p(.class("section-intro")) {
                            "Steps run from top to bottom. Add another only when it uses an earlier result."
                        }
                    }
                }
            }
            HTMLRaw("<script>\(Self.editorScript)</script>")
        }
    }

    static let editorScript = """
        (() => {
          const editor = document.querySelector("[data-tool-editor]");
          if (!editor) return;

          const setHidden = (element, hidden) => {
            element.hidden = hidden;
            element.dataset.active = hidden ? "false" : "true";
          };

          const updateBody = () => {
            const kind = editor.querySelector("[data-body-kind]")?.value || "workflow";
            editor.querySelectorAll("[data-body-section]").forEach((section) => {
              setHidden(section, section.dataset.bodySection !== kind);
            });
          };

          const updateStage = (stage) => {
            const kind = stage.querySelector("[data-stage-kind]")?.value || "fetch";
            stage.querySelectorAll("[data-stage-panel]").forEach((panel) => {
              setHidden(panel, panel.dataset.stagePanel !== kind);
            });
            const mode = stage.querySelector("[data-script-mode]")?.value || "source";
            stage.querySelectorAll("[data-script-panel]").forEach((panel) => {
              setHidden(panel, panel.dataset.scriptPanel !== mode);
            });
          };

          const updateStageNumbers = () => {
            editor.querySelectorAll("[data-stage-row]:not([data-builder-template])").forEach((stage, index) => {
              const number = stage.querySelector("[data-stage-number]");
              if (number) number.textContent = String(index + 1);
            });
          };

          const updateStageListState = () => {
            const list = editor.querySelector("[data-stage-list]");
            const hasStages = Boolean(
              list?.querySelector("[data-stage-row]:not([data-builder-template])")
            );
            const emptyAdd = editor.querySelector("[data-empty-add]");
            if (emptyAdd) emptyAdd.hidden = hasStages;
          };

          const cloneRow = (kind) => {
            const template = editor.querySelector(
              "[data-builder-template='" + kind + "']"
            );
            if (!template) return null;

            const row = template.cloneNode(true);
            row.hidden = false;
            row.removeAttribute("data-builder-template");
            row.setAttribute("data-builder-visible", "true");
            row.setAttribute("data-visible", "true");
            row.querySelectorAll("input, textarea").forEach((field) => {
              field.value = "";
            });
            row.querySelectorAll("[data-required]").forEach((field) => {
              field.required = true;
            });
            row.querySelectorAll("select").forEach((field) => {
              field.selectedIndex = 0;
            });
            return { row, template };
          };

          const finishAddedRow = (row) => {
            if (row.matches("[data-stage-row]")) {
              updateStage(row);
              updateStageNumbers();
              if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
                row.classList.add("builder-row-entering");
              }
              updateStageListState();
            }
          };

          const removeRow = (row, finish) => {
            if (!row?.matches("[data-stage-row]") ||
                window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
              finish();
              return;
            }

            let completed = false;
            const complete = () => {
              if (completed) return;
              completed = true;
              finish();
            };
            row.addEventListener("animationend", complete, { once: true });
            row.classList.add("builder-row-removing");
            window.setTimeout(complete, 240);
          };

          editor.addEventListener("change", (event) => {
            if (event.target.matches("[data-body-kind]")) updateBody();
            const stage = event.target.closest("[data-stage-row]");
            if (stage && (event.target.matches("[data-stage-kind]") ||
                          event.target.matches("[data-script-mode]"))) {
              updateStage(stage);
            }
          });

          editor.addEventListener("click", (event) => {
            const insertAfter = event.target.closest("[data-add-after]");
            if (insertAfter) {
              const stage = insertAfter.closest("[data-stage-row]");
              const cloned = cloneRow(insertAfter.dataset.addAfter);
              if (!stage || !cloned) return;
              stage.after(cloned.row);
              finishAddedRow(cloned.row);
              return;
            }

            const add = event.target.closest("[data-add-row]");
            if (add) {
              const cloned = cloneRow(add.dataset.addRow);
              if (!cloned) return;
              const list = cloned.template.parentElement;
              list?.insertBefore(cloned.row, cloned.template);
              if (list?.dataset.empty !== undefined) list.dataset.empty = "false";
              finishAddedRow(cloned.row);
              return;
            }

            const remove = event.target.closest("[data-remove-row]");
            if (remove) {
              const row = remove.closest("[data-builder-row]");
              const list = row?.parentElement;
              const isArgument = row?.dataset.builderRow === "argument";
              removeRow(row, () => {
                row?.remove();
                if (isArgument && list?.dataset.empty !== undefined) {
                  list.dataset.empty = list.querySelector("[data-builder-visible]") ? "false" : "true";
                }
                updateStageNumbers();
                updateStageListState();
              });
            }
          });

          updateBody();
          editor.querySelectorAll("[data-stage-row]:not([data-builder-template])").forEach(updateStage);
          updateStageNumbers();
          updateStageListState();
        })();
        """
}
