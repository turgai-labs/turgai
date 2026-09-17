import AnyLanguageModel
import Elementary
import TurgaiApplication

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct TurgaiToolsPage: HTMLDocument, Sendable {
    let user: AuthenticatedUser
    let documents: [UserToolDocument]
    let error: String?

    init(
        user: AuthenticatedUser,
        documents: [UserToolDocument],
        error: String? = nil
    ) {
        self.user = user
        self.documents = documents
        self.error = error
    }

    var title: String { "Turgai — Tools" }
    var head: some HTML { TurgaiHead() }

    var body: some HTML {
        main(.class("app-page")) {
            div(.class("app-shell tools-shell")) {
                AppHeader(user: user, section: .tools)
                section(.class("page-intro")) {
                    div {
                        p(.class("eyebrow")) { "Your capabilities" }
                        h1 { "Tools" }
                        p(.class("lede")) {
                            "Give your bots useful abilities, one clear step at a time."
                        }
                    }
                    a(.href("/tools/new"), .class("button button-accent add-tool-link")) { "+ New tool" }
                }
                if let error {
                    p(.class("error page-error")) { error }
                }
                if documents.isEmpty {
                    div(.class("empty-state")) {
                        p(.class("eyebrow")) { "A blank canvas" }
                        h2 { "Start with one useful ability." }
                        p(.class("section-intro")) {
                            "Fetch information, run a script, or ask another bot to take on one focused piece of thinking."
                        }
                        a(.href("/tools/new"), .class("text-link")) { "New tool →" }
                    }
                } else {
                    section(.class("tools-list")) {
                        for document in documents {
                            TurgaiToolRow(document: document)
                        }
                    }
                }
            }
        }
    }
}

private struct TurgaiToolRow: HTML, Sendable {
    let document: UserToolDocument

    private var href: String { "/tools/\(document.fileName)" }

    private var kind: String {
        guard let tool = document.tool else { return "unavailable" }
        switch tool.body {
        case .workflow(let workflow):
            return "\(workflow.steps.count) steps"
        case .process:
            return "program"
        case .wasm:
            return "module"
        case .prompt:
            return "prompt"
        }
    }

    var body: some HTML {
        div(.class("tool-row \(document.isValid ? "" : "tool-row-invalid")")) {
            div(.class("tool-row-main")) {
                if let tool = document.tool {
                    a(.href(href), .class("tool-name")) { tool.name }
                    p(.class("tool-description")) { tool.description }
                } else {
                    a(.href(href), .class("tool-name")) { "Tool needs attention" }
                    p(.class("tool-description tool-issue")) {
                        "This tool could not be loaded. Open it to repair or remove it."
                    }
                }
            }
            div(.class("tool-row-meta")) {
                span(.class("tool-meta-label")) { "Kind" }
                span { kind }
            }
            div(.class("tool-row-meta")) {
                span(.class("tool-meta-label")) { "Approval" }
                span {
                    if let tool = document.tool {
                        tool.approval.rawValue == "always" ? "asks first" : "runs directly"
                    } else {
                        "unavailable"
                    }
                }
            }
            a(.href(href), .class("tool-row-action")) {
                document.isValid ? "Edit →" : "Review →"
            }
        }
    }
}

enum TurgaiToolBodyKind: String, Sendable {
    case workflow
    case process
    case prompt
    case wasm

    var label: String {
        switch self {
        case .workflow: "Workflow"
        case .process: "Run a program"
        case .prompt: "Ask another bot"
        case .wasm: "Run a module"
        }
    }
}

struct TurgaiToolArgumentDraft: Sendable {
    var name = ""
    var type: ToolArgumentType = .string
    var description = ""
    var required = false
}

struct TurgaiWorkflowStepDraft: Sendable {
    var id = ""
    var kind: WorkflowStepKind = .fetch
    var saveAs = ""
    var permission: WorkflowPermission = .inherit
    var allowedHosts = ""
    var writeDirectory = ""
    var url = ""
    var method = "GET"
    var headers = ""
    var body = ""
    var scriptMode: ScriptSource = .source
    var scriptSource = ""
    var scriptFile = ""
    var interpreter = "bash"
    var arguments = ""
    var environment = ""
    var inputs = ""
    var instruction = ""

    init() {}

    init(
        id: String = "",
        kind: WorkflowStepKind = .fetch,
        saveAs: String = "",
        permission: WorkflowPermission = .inherit,
        allowedHosts: String = "",
        writeDirectory: String = "",
        url: String = "",
        method: String = "GET",
        headers: String = "",
        body: String = "",
        scriptMode: ScriptSource = .source,
        scriptSource: String = "",
        scriptFile: String = "",
        interpreter: String = "bash",
        arguments: String = "",
        environment: String = "",
        inputs: String = "",
        instruction: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.saveAs = saveAs
        self.permission = permission
        self.allowedHosts = allowedHosts
        self.writeDirectory = writeDirectory
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.scriptMode = scriptMode
        self.scriptSource = scriptSource
        self.scriptFile = scriptFile
        self.interpreter = interpreter
        self.arguments = arguments
        self.environment = environment
        self.inputs = inputs
        self.instruction = instruction
    }

    init(step: UserTool.WorkflowStep) {
        self.id = step.id
        self.kind = WorkflowStepKind(rawValue: step.kind.rawValue) ?? .fetch
        self.saveAs = step.saveAs ?? ""
        self.permission = WorkflowPermission(rawValue: step.permission?.rawValue ?? "") ?? .inherit
        self.allowedHosts = Self.lines(step.allowedHosts ?? [])
        self.writeDirectory = step.writeDirectory ?? ""
        self.url = step.url ?? ""
        self.method = step.method ?? "GET"
        self.headers = Self.headerLines(step.headers ?? [:])
        self.body = step.body ?? ""
        self.scriptMode = step.scriptSource == nil ? .file : .source
        self.scriptSource = step.scriptSource ?? ""
        self.scriptFile = step.script ?? ""
        self.interpreter = step.interpreter ?? ""
        self.arguments = Self.lines(step.arguments ?? [])
        self.environment = Self.headerLines(step.environment ?? [:], separator: "=")
        self.inputs = Self.headerLines(step.inputs ?? [:], separator: "=")
        self.instruction = step.instruction ?? ""
    }

    fileprivate static func lines(_ values: [String]) -> String {
        values.joined(separator: "\n")
    }

    fileprivate static func headerLines(
        _ values: [String: String],
        separator: String = ": "
    ) -> String {
        values.keys.sorted().map { "\($0)\(separator)\(values[$0] ?? "")" }.joined(separator: "\n")
    }
}

struct TurgaiToolDraft: Sendable {
    var fileName: String
    var isNew: Bool
    var name: String
    var description: String
    var approval: String
    var bodyKind: TurgaiToolBodyKind
    var arguments: [TurgaiToolArgumentDraft]
    var workflowSteps: [TurgaiWorkflowStepDraft]
    var processExecutable: String
    var processArguments: String
    var processEnvironment: String
    var wasmModule: String
    var promptInstruction: String

    init(
        fileName: String,
        isNew: Bool,
        name: String,
        description: String,
        approval: String,
        bodyKind: TurgaiToolBodyKind,
        arguments: [TurgaiToolArgumentDraft],
        workflowSteps: [TurgaiWorkflowStepDraft],
        processExecutable: String,
        processArguments: String,
        processEnvironment: String,
        wasmModule: String,
        promptInstruction: String
    ) {
        self.fileName = fileName
        self.isNew = isNew
        self.name = name
        self.description = description
        self.approval = approval
        self.bodyKind = bodyKind
        self.arguments = arguments
        self.workflowSteps = workflowSteps
        self.processExecutable = processExecutable
        self.processArguments = processArguments
        self.processEnvironment = processEnvironment
        self.wasmModule = wasmModule
        self.promptInstruction = promptInstruction
    }

    static func new(fileName: String) -> Self {
        var draft = Self(
            fileName: fileName,
            isNew: true,
            name: "",
            description: "",
            approval: "always",
            bodyKind: .workflow,
            arguments: [],
            workflowSteps: [TurgaiWorkflowStepDraft(id: "step-1")],
            processExecutable: "",
            processArguments: "",
            processEnvironment: "",
            wasmModule: "",
            promptInstruction: ""
        )
        draft.workflowSteps[0].kind = .fetch
        return draft
    }

    init(document: UserToolDocument) {
        self.fileName = document.fileName
        self.isNew = false
        self.name = document.tool?.name ?? ""
        self.description = document.tool?.description ?? ""
        self.approval = document.tool?.approval.rawValue ?? "always"
        self.arguments = document.tool.map { Self.argumentDrafts(from: $0.arguments) } ?? []
        self.workflowSteps = []
        self.processExecutable = ""
        self.processArguments = ""
        self.processEnvironment = ""
        self.wasmModule = ""
        self.promptInstruction = ""

        guard let tool = document.tool else {
            self.bodyKind = .workflow
            self.workflowSteps = [TurgaiWorkflowStepDraft(id: "step-1")]
            return
        }

        switch tool.body {
        case .workflow(let workflow):
            self.bodyKind = .workflow
            self.workflowSteps = workflow.steps.map(TurgaiWorkflowStepDraft.init)
        case .process(let process):
            self.bodyKind = .process
            self.processExecutable = process.argv.first ?? ""
            self.processArguments = process.argv.dropFirst().joined(separator: "\n")
            self.processEnvironment = TurgaiWorkflowStepDraft.headerLines(
                process.environment ?? [:],
                separator: "="
            )
        case .prompt(let prompt):
            self.bodyKind = .prompt
            self.promptInstruction = prompt.instruction
        case .wasm(let wasm):
            self.bodyKind = .wasm
            self.wasmModule = Self.relativeModulePath(wasm.module, source: tool.source)
        }
    }

    init(form: [String: [String]], fileName: String, isNew: Bool) {
        self.fileName = fileName
        self.isNew = isNew
        self.name = form["toolName"]?.first ?? ""
        self.description = form["toolDescription"]?.first ?? ""
        self.approval = form["approval"]?.first ?? "always"
        self.bodyKind = TurgaiToolBodyKind(rawValue: form["bodyKind"]?.first ?? "") ?? .workflow

        let argumentCount = form["argumentName"]?.count ?? 0
        self.arguments = (0..<argumentCount).map { index in
            TurgaiToolArgumentDraft(
                name: form["argumentName"]?[safe: index] ?? "",
                type: ToolArgumentType(rawValue: form["argumentType"]?[safe: index] ?? "") ?? .string,
                description: form["argumentDescription"]?[safe: index] ?? "",
                required: form["argumentRequired"]?[safe: index] == "required"
            )
        }

        let stepCount = form["stageID"]?.count ?? 0
        self.workflowSteps = (0..<stepCount).map { index in
            TurgaiWorkflowStepDraft(
                id: form["stageID"]?[safe: index] ?? "",
                kind: WorkflowStepKind(rawValue: form["stageKind"]?[safe: index] ?? "") ?? .fetch,
                saveAs: form["stageSaveAs"]?[safe: index] ?? "",
                permission: WorkflowPermission(rawValue: form["stagePermission"]?[safe: index] ?? "") ?? .inherit,
                allowedHosts: form["stageAllowedHosts"]?[safe: index] ?? "",
                writeDirectory: form["stageWriteDirectory"]?[safe: index] ?? "",
                url: form["stageURL"]?[safe: index] ?? "",
                method: form["stageMethod"]?[safe: index] ?? "GET",
                headers: form["stageHeaders"]?[safe: index] ?? "",
                body: form["stageBody"]?[safe: index] ?? "",
                scriptMode: ScriptSource(rawValue: form["stageScriptMode"]?[safe: index] ?? "") ?? .source,
                scriptSource: form["stageScriptSource"]?[safe: index] ?? "",
                scriptFile: form["stageScriptFile"]?[safe: index] ?? "",
                interpreter: form["stageInterpreter"]?[safe: index] ?? "bash",
                arguments: form["stageArguments"]?[safe: index] ?? "",
                environment: form["stageEnvironment"]?[safe: index] ?? "",
                inputs: form["stageInputs"]?[safe: index] ?? "",
                instruction: form["stageInstruction"]?[safe: index] ?? ""
            )
        }
        self.processExecutable = form["processExecutable"]?.first ?? ""
        self.processArguments = form["processArguments"]?.first ?? ""
        self.processEnvironment = form["processEnvironment"]?.first ?? ""
        self.wasmModule = form["wasmModule"]?.first ?? ""
        self.promptInstruction = form["promptInstruction"]?.first ?? ""
    }

    func encodedDefinition() throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw TurgaiToolDraftError.invalid("Give the tool a name.") }
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            throw TurgaiToolDraftError.invalid("Describe what the tool does.")
        }
        guard let approvalPolicy = UserTool.ApprovalPolicy(rawValue: approval) else {
            throw TurgaiToolDraftError.invalid("Choose when the tool may run.")
        }

        var root: [String: Any] = [
            "version": 1,
            "name": trimmedName,
            "description": trimmedDescription,
            "approval": approvalPolicy.rawValue,
            "arguments": try argumentSchema(),
        ]

        switch bodyKind {
        case .workflow:
            let steps = try workflowDefinition()
            root["body"] = ["kind": "workflow", "steps": steps]
        case .process:
            let argv = try processDefinition()
            root["body"] = [
                "kind": "process",
                "argv": argv,
                "environment": try environmentDefinition(processEnvironment),
            ]
        case .prompt:
            let instruction = promptInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else {
                throw TurgaiToolDraftError.invalid("Write the instruction for the other bot.")
            }
            root["body"] = ["kind": "prompt", "instruction": instruction]
        case .wasm:
            let module = wasmModule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !module.isEmpty, !module.hasPrefix("/"), module.hasSuffix(".wasm") else {
                throw TurgaiToolDraftError.invalid("Choose a relative .wasm module.")
            }
            root["body"] = ["kind": "wasm", "module": module]
        }

        do {
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw TurgaiToolDraftError.invalid("The tool could not be prepared for saving.")
        }
    }

    private func argumentSchema() throws -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        var names: Set<String> = []

        for argument in arguments {
            let name = argument.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty, argument.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            guard !name.isEmpty else {
                throw TurgaiToolDraftError.invalid("Every input needs a name.")
            }
            guard names.insert(name).inserted else {
                throw TurgaiToolDraftError.invalid("Input '\(name)' is listed more than once.")
            }
            var property: [String: Any] = ["type": argument.type.rawValue]
            let description = argument.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty { property["description"] = description }
            properties[name] = property
            if argument.required { required.append(name) }
        }

        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
        ]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private func workflowDefinition() throws -> [[String: Any]] {
        let activeSteps = workflowSteps.filter { step in
            !step.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !step.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !step.scriptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !step.scriptFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !step.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !activeSteps.isEmpty else {
            throw TurgaiToolDraftError.invalid("Add at least one workflow step.")
        }

        var result: [[String: Any]] = []
        for (index, step) in activeSteps.enumerated() {
            let id = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw TurgaiToolDraftError.invalid("Step \(index + 1) needs a name.")
            }
            var definition: [String: Any] = [
                "id": id,
                "kind": step.kind.rawValue,
                "permission": step.permission.rawValue,
            ]
            let saveAs = step.saveAs.trimmingCharacters(in: .whitespacesAndNewlines)
            if !saveAs.isEmpty { definition["saveAs"] = saveAs }
            let inputs = try pairs(step.inputs, separator: "=")
            if !inputs.isEmpty { definition["inputs"] = inputs }

            switch step.kind {
            case .fetch:
                let url = step.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { throw TurgaiToolDraftError.invalid("Fetch step '\(id)' needs a URL.") }
                definition["url"] = url
                let method = step.method.trimmingCharacters(in: .whitespacesAndNewlines)
                if !method.isEmpty { definition["method"] = method.uppercased() }
                let hosts = commaList(step.allowedHosts)
                if let hosts { definition["allowedHosts"] = hosts }
                let headers = try pairs(step.headers, separator: ":")
                if !headers.isEmpty { definition["headers"] = headers }
                let body = step.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { definition["body"] = body }
            case .execute:
                let source = step.scriptSource.trimmingCharacters(in: .whitespacesAndNewlines)
                let file = step.scriptFile.trimmingCharacters(in: .whitespacesAndNewlines)
                if step.scriptMode == .file {
                    guard !file.isEmpty else {
                        throw TurgaiToolDraftError.invalid("Execute step '\(id)' needs a script file.")
                    }
                    definition["script"] = file
                } else {
                    guard !source.isEmpty else {
                        throw TurgaiToolDraftError.invalid("Execute step '\(id)' needs a script.")
                    }
                    definition["scriptSource"] = source
                }
                let interpreter = step.interpreter.trimmingCharacters(in: .whitespacesAndNewlines)
                if step.scriptMode != .file, interpreter.isEmpty {
                    throw TurgaiToolDraftError.invalid(
                        "Choose an interpreter for the script in step '\(id)'."
                    )
                }
                if !interpreter.isEmpty { definition["interpreter"] = interpreter }
                let arguments = nonEmptyLines(step.arguments)
                if !arguments.isEmpty { definition["arguments"] = arguments }
                let environment = try environmentDefinition(step.environment)
                if !environment.isEmpty { definition["environment"] = environment }
                let directory = step.writeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                if !directory.isEmpty { definition["writeDirectory"] = directory }
            case .think:
                let instruction = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !instruction.isEmpty else {
                    throw TurgaiToolDraftError.invalid("Think step '\(id)' needs an instruction.")
                }
                definition["instruction"] = instruction
            }
            result.append(definition)
        }
        return result
    }

    private func processDefinition() throws -> [String] {
        let executable = processExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else { throw TurgaiToolDraftError.invalid("Choose a program to run.") }
        return [executable] + nonEmptyLines(processArguments)
    }

    private func environmentDefinition(_ value: String) throws -> [String: String] {
        try pairs(value, separator: "=")
    }

    private func pairs(_ value: String, separator: Character) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in value.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let split = trimmed.firstIndex(of: separator) else {
                throw TurgaiToolDraftError.invalid("Use one \(separator) between each name and value.")
            }
            let key = String(trimmed[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            let item = String(trimmed[trimmed.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw TurgaiToolDraftError.invalid("A name cannot be empty.") }
            guard result[key] == nil else {
                throw TurgaiToolDraftError.invalid("The name '\(key)' is listed more than once.")
            }
            result[key] = item
        }
        return result
    }

    private func commaList(_ value: String) -> [String]? {
        var seen: Set<String> = []
        let values = value.split { $0 == "," || $0.isNewline }.compactMap { part -> String? in
            let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
        return values.isEmpty ? nil : values
    }

    private func nonEmptyLines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private static func argumentDrafts(from schema: GenerationSchema) -> [TurgaiToolArgumentDraft] {
        guard let data = try? JSONEncoder().encode(schema),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let properties = root["properties"] as? [String: Any]
        else { return [] }
        let required = Set(root["required"] as? [String] ?? [])
        return properties.keys.sorted().map { name in
            let property = properties[name] as? [String: Any]
            return TurgaiToolArgumentDraft(
                name: name,
                type: ToolArgumentType(rawValue: property?["type"] as? String ?? "") ?? .string,
                description: property?["description"] as? String ?? "",
                required: required.contains(name)
            )
        }
    }

    private static func relativeModulePath(_ module: URL, source: URL) -> String {
        let directory = source.deletingLastPathComponent().standardizedFileURL.path
        let path = module.standardizedFileURL.path
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : module.lastPathComponent
    }
}

enum TurgaiToolDraftError: Error, Sendable, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): message
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

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

    var title: String { "Turgai — \(draft.isNew ? "New tool" : "Edit tool")" }
    var head: some HTML { TurgaiHead() }

    private var heading: String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (draft.isNew ? "Build a tool" : "Edit tool") : name
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
                            currentTitle: draft.isNew ? "New tool" : "Edit tool"
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
                            input(.type(.hidden), .name("isNew"), .value(String(draft.isNew)))

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
                                            TurgaiToolArgumentRow(argument: argument, isTemplate: false)
                                        }
                                        TurgaiToolArgumentRow(
                                            argument: TurgaiToolArgumentDraft(),
                                            isTemplate: true
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
                        if !draft.isNew {
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

private struct TurgaiSelect: HTML, Sendable {
    let name: String
    let value: String
    let options: [(String, String)]
    let dataAttribute: String?

    init(
        name: String,
        value: String,
        options: [(String, String)],
        dataAttribute: String? = nil
    ) {
        self.name = name
        self.value = value
        self.options = options
        self.dataAttribute = dataAttribute
    }

    var body: some HTML {
        if let dataAttribute {
            select(.name(name), .init(name: dataAttribute, value: "")) {
                TurgaiSelectOptions(options: options, value: value)
            }
        } else {
            select(.name(name)) {
                TurgaiSelectOptions(options: options, value: value)
            }
        }
    }
}

private struct TurgaiSelectOptions: HTML, Sendable {
    let options: [(String, String)]
    let value: String

    var body: some HTML {
        for optionValue in options {
            TurgaiSelectOption(
                value: optionValue.0,
                label: optionValue.1,
                selected: optionValue.0 == value
            )
        }
    }
}

private struct TurgaiSelectOption: HTML, Sendable {
    let value: String
    let label: String
    let selected: Bool

    var body: some HTML {
        if selected {
            option(.value(value), .selected) { label }
        } else {
            option(.value(value)) { label }
        }
    }
}

private struct TurgaiToolArgumentRow: HTML, Sendable {
    let argument: TurgaiToolArgumentDraft
    let isTemplate: Bool

    var body: some HTML {
        div(
            .class("builder-row argument-row"),
            .init(name: "data-builder-row", value: "argument"),
            isTemplate
                ? .init(name: "data-builder-template", value: "arguments")
                : .init(name: "data-builder-visible", value: "true"),
            isTemplate ? .hidden : .init(name: "data-visible", value: "true")
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

private struct TurgaiWorkflowBuilder: HTML, Sendable {
    let steps: [TurgaiWorkflowStepDraft]

    var body: some HTML {
        div(
            .class("builder-body-section"),
            .init(name: "data-body-section", value: "workflow")
        ) {
            p(.class("builder-hint")) {
                "Runs from top to bottom. Start with one step, then add another when it needs the first step's result."
            }
            div(
                .class("builder-list"),
                .init(name: "data-stage-list", value: "")
            ) {
                for (index, step) in steps.enumerated() {
                    TurgaiWorkflowStageRow(step: step, number: index + 1, isTemplate: false)
                }
                TurgaiWorkflowStageRow(
                    step: TurgaiWorkflowStepDraft(),
                    number: 1,
                    isTemplate: true
                )
            }
            button(
                .type(.button),
                .class("builder-add"),
                .init(name: "data-add-row", value: "stages"),
                .init(name: "data-empty-add", value: ""),
                steps.isEmpty ? .init(name: "data-visible", value: "true") : .hidden
            ) {
                "+ Add step"
            }
        }
    }
}

private struct TurgaiWorkflowStageRow: HTML, Sendable {
    let step: TurgaiWorkflowStepDraft
    let number: Int
    let isTemplate: Bool

    private var hasStepOptions: Bool {
        !step.saveAs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || step.permission != .inherit
            || !step.inputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some HTML {
        div(
            .class("builder-row workflow-stage-row"),
            .init(name: "data-builder-row", value: "stage"),
            .init(name: "data-stage-row", value: ""),
            isTemplate
                ? .init(name: "data-builder-template", value: "stages")
                : .init(name: "data-builder-visible", value: "true"),
            isTemplate ? .hidden : .init(name: "data-visible", value: "true")
        ) {
            div(.class("stage-heading")) {
                span(.class("stage-number"), .init(name: "data-stage-number", value: "")) {
                    String(number)
                }
                TurgaiSelect(
                    name: "stageKind",
                    value: step.kind.rawValue,
                    options: [
                        ("fetch", "Get information"),
                        ("execute", "Run a script"),
                        ("think", "Explain a result"),
                    ],
                    dataAttribute: "data-stage-kind"
                )
                button(
                    .type(.button),
                    .class("builder-remove"),
                    .init(name: "data-remove-row", value: "stage"),
                    .init(name: "aria-label", value: "Remove step"),
                    .init(name: "title", value: "Remove step")
                ) {
                    "×"
                }
            }
            div(.class("stage-primary-fields")) {
                label(.class("form-field")) {
                    span(.class("field-label")) { "Step name" }
                    if isTemplate {
                        input(
                            .type(.text),
                            .name("stageID"),
                            .value(step.id),
                            .placeholder("forecast"),
                            .init(name: "data-required", value: "true")
                        )
                    } else {
                        input(
                            .type(.text),
                            .name("stageID"),
                            .value(step.id),
                            .placeholder("forecast"),
                            .required
                        )
                    }
                    p(.class("hint")) { "A short name for what this step returns." }
                }
            }
            TurgaiFetchStageFields(step: step)
            TurgaiExecuteStageFields(step: step)
            TurgaiThinkStageFields(step: step)
            details(.class("stage-details")) {
                summary(.class("stage-details-summary")) {
                    hasStepOptions ? "Optional step settings (configured)" : "Optional step settings"
                }
                div(.class("builder-grid builder-grid-two")) {
                    label(.class("form-field")) {
                        span(.class("field-label")) { "Output name" }
                        input(
                            .type(.text),
                            .name("stageSaveAs"),
                            .value(step.saveAs),
                            .placeholder("forecast")
                        )
                        p(.class("hint")) { "Give this result another name if a later step needs it." }
                    }
                    label(.class("form-field")) {
                        span(.class("field-label")) { "Permission" }
                        TurgaiSelect(
                            name: "stagePermission",
                            value: step.permission.rawValue,
                            options: [
                                ("inherit", "Use tool access"),
                                ("allowed", "Allow this step"),
                                ("denied", "Block this step"),
                            ]
                        )
                    }
                }
                label(.class("form-field builder-wide-field")) {
                    span(.class("field-label")) { "Earlier results" }
                    textarea(
                        .name("stageInputs"),
                        .init(name: "rows", value: "2"),
                        .placeholder("forecast=step-1")
                    ) {
                        step.inputs
                    }
                    p(.class("hint")) { "Pass saved results as name=value, one per line." }
                }
            }
            div(.class("stage-row-footer")) {
                button(
                    .type(.button),
                    .class("builder-add"),
                    .init(name: "data-add-after", value: "stages"),
                    .init(name: "aria-label", value: "Add step after this step"),
                    .init(name: "title", value: "Add step after this step")
                ) {
                    "+ Add step"
                }
            }
        }
    }
}

private struct TurgaiFetchStageFields: HTML, Sendable {
    let step: TurgaiWorkflowStepDraft

    private var hasConnectionOptions: Bool {
        step.method.uppercased() != "GET"
            || !step.allowedHosts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !step.headers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !step.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

private struct TurgaiExecuteStageFields: HTML, Sendable {
    let step: TurgaiWorkflowStepDraft

    private var hasScriptOptions: Bool {
        !step.writeDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !step.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !step.environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
                    options: [
                        ("source", "Write it here"),
                        ("file", "Use a file next to this tool"),
                    ],
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
            details(.class("stage-details")) {
                summary(.class("stage-details-summary")) {
                    hasScriptOptions
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
}

private struct TurgaiThinkStageFields: HTML, Sendable {
    let step: TurgaiWorkflowStepDraft

    var body: some HTML {
        div(
            .class("stage-kind-panel"),
            .init(name: "data-stage-panel", value: "think")
        ) {
            label(.class("form-field")) {
                span(.class("field-label")) { "Instruction" }
                textarea(
                    .name("stageInstruction"),
                    .init(name: "rows", value: "6"),
                    .placeholder("Explain the result in one short paragraph.")
                ) {
                    step.instruction
                }
                p(.class("hint")) {
                    "Use this to explain, summarize, or reshape the current result."
                }
            }
        }
    }
}

private struct TurgaiProgramBuilder: HTML, Sendable {
    let executable: String
    let arguments: String
    let environment: String

    private var hasOptions: Bool {
        !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

private struct TurgaiPromptBuilder: HTML, Sendable {
    let instruction: String

    var body: some HTML {
        div(
            .class("builder-body-section"),
            .init(name: "data-body-section", value: "prompt")
        ) {
            p(.class("section-intro")) {
                "Ask another bot to take on one focused piece of thinking and bring back its answer."
            }
            label(.class("form-field")) {
                span(.class("field-label")) { "Instruction" }
                textarea(
                    .name("promptInstruction"),
                    .init(name: "rows", value: "10"),
                    .placeholder("Summarize the information for {{city}}.")
                ) {
                    instruction
                }
                p(.class("hint")) {
                    "Use {{input}} to include an input from above."
                }
            }
        }
    }
}

private struct TurgaiWasmBuilder: HTML, Sendable {
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
