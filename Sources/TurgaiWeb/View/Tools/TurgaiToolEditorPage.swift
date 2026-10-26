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
            PageShell(
                kind: .private,
                header: PageHeader(user: user, navigation: .active(.tools)),
                footer: PageFooter { EmptyFooterContent() }
            ) {
                intro
                problem
                div(.class("tool-editor-layout")) {
                    section(.class("tool-editor-main")) {
                        p(.class("detail-note tool-editor-note")) {
                            "Changes take effect the next time this bot is activated. Conversations already running keep their current agent."
                        }
                        editorForm
                        if case .existing = draft.kind { ToolRemoval(fileName: draft.fileName) }
                    }
                    guide
                }
            }
            HTMLRaw("<script>\(Self.editorScript)</script>")
        }
    }

    @HTMLBuilder private var intro: some HTML & Sendable {
        section(.class("page-intro detail-page-intro")) {
            div {
                TurgaiBreadcrumb(parentTitle: "Tools", parentHref: "/tools", currentTitle: draftLabel)
                h1 { heading }
                p(.class("lede")) {
                    "Give it a clear purpose, choose how it works, and add steps only when they earn their place."
                }
            }
        }
    }

    @HTMLBuilder private var problem: some HTML & Sendable {
        switch (error, issue) {
        case (.some(let error), _):
            p(.class("error page-error")) { error }
        case (.none, .some):
            p(.class("error page-error")) {
                "This tool needs attention. Repair its setup below or remove it."
            }
        default:
            EmptyFooterContent()
        }
    }

    @HTMLBuilder private var editorForm: some HTML & Sendable {
        form(
            .method(.post),
            .action("/tools/save"),
            .class("tool-editor-form"),
            .init(name: "data-tool-editor", value: "")
        ) {
            input(.type(.hidden), .name("fileName"), .value(draft.fileName))
            input(.type(.hidden), .name("isNew"), .value(draftKindValue))
            ToolNameAndAccess(draft: draft)
            ToolInputs(arguments: draft.arguments)
            ToolAction(draft: draft)
            div(.class("form-actions")) {
                button(.type(.submit), .class("button button-accent")) { "Save tool" }
                a(.href("/tools"), .class("button button-secondary")) { "Cancel" }
            }
        }
    }

    @HTMLBuilder private var guide: some HTML & Sendable {
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
