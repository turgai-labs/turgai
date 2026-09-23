import TurgaiApplication

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

enum ToolDraftError: Error, Sendable, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): message
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
        self.permission = WorkflowPermission(rawValue: step.permission.rawValue) ?? .inherit
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

    static func headerLines(
        _ values: [String: String],
        separator: String = ": "
    ) -> String {
        values.keys.sorted().map { "\($0)\(separator)\(values[$0] ?? "")" }.joined(separator: "\n")
    }
}

enum ToolDraftKind: Sendable {
    case new
    case existing
}

struct TurgaiToolDraft: Sendable {
    var fileName: String
    var kind: ToolDraftKind
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
        kind: ToolDraftKind,
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
        self.kind = kind
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
            kind: .new,
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

    func encodedDefinition() throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ToolDraftError.invalid("Give the tool a name.") }
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else { throw ToolDraftError.invalid("Describe what the tool does.") }
        guard let approvalPolicy = UserTool.ApprovalPolicy(rawValue: approval) else {
            throw ToolDraftError.invalid("Choose when the tool may run.")
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
            root["body"] = ["kind": "workflow", "steps": try workflowDefinition()]
        case .process:
            root["body"] = [
                "kind": "process",
                "argv": try processDefinition(),
                "environment": try environmentDefinition(processEnvironment),
            ]
        case .prompt:
            let instruction = promptInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { throw ToolDraftError.invalid("Write the instruction for the other bot.") }
            root["body"] = ["kind": "prompt", "instruction": instruction]
        case .wasm:
            let module = wasmModule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !module.isEmpty, !module.hasPrefix("/"), module.hasSuffix(".wasm") else {
                throw ToolDraftError.invalid("Choose a relative .wasm module.")
            }
            root["body"] = ["kind": "wasm", "module": module]
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw ToolDraftError.invalid("The tool could not be prepared for saving.")
        }
    }

    private func argumentSchema() throws -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        var names: Set<String> = []
        for argument in arguments {
            let name = argument.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty, argument.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard !name.isEmpty else { throw ToolDraftError.invalid("Every input needs a name.") }
            guard names.insert(name).inserted else {
                throw ToolDraftError.invalid("Input '\(name)' is listed more than once.")
            }
            var property: [String: Any] = ["type": argument.type.rawValue]
            let description = argument.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty { property["description"] = description }
            properties[name] = property
            if argument.required { required.append(name) }
        }
        var schema: [String: Any] = ["type": "object", "properties": properties]
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
        guard !activeSteps.isEmpty else { throw ToolDraftError.invalid("Add at least one workflow step.") }
        var result: [[String: Any]] = []
        for (index, step) in activeSteps.enumerated() {
            let id = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw ToolDraftError.invalid("Step \(index + 1) needs a name.") }
            var definition: [String: Any] = [
                "id": id, "permission": step.permission.rawValue,
            ]
            let saveAs = step.saveAs.trimmingCharacters(in: .whitespacesAndNewlines)
            if !saveAs.isEmpty { definition["saveAs"] = saveAs }
            let inputs = try pairs(step.inputs, separator: "=")
            if !inputs.isEmpty { definition["inputs"] = inputs }
            switch step.kind {
            case .fetch:
                var payload: [String: Any] = [:]
                let url = step.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { throw ToolDraftError.invalid("Fetch step '\(id)' needs a URL.") }
                payload["url"] = url
                let method = step.method.trimmingCharacters(in: .whitespacesAndNewlines)
                if !method.isEmpty { payload["method"] = method.uppercased() }
                if let hosts = commaList(step.allowedHosts) { payload["allowedHosts"] = hosts }
                let headers = try pairs(step.headers, separator: ":")
                if !headers.isEmpty { payload["headers"] = headers }
                let body = step.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { payload["body"] = body }
                definition["payload"] = ["fetch": payload]
            case .execute:
                var payload: [String: Any] = [:]
                let source = step.scriptSource.trimmingCharacters(in: .whitespacesAndNewlines)
                let file = step.scriptFile.trimmingCharacters(in: .whitespacesAndNewlines)
                if step.scriptMode == .file {
                    guard !file.isEmpty else {
                        throw ToolDraftError.invalid("Execute step '\(id)' needs a script file.")
                    }
                    payload["script"] = ["path": file]
                } else {
                    guard !source.isEmpty else { throw ToolDraftError.invalid("Execute step '\(id)' needs a script.") }
                    payload["script"] = ["inline": source]
                }
                let interpreter = step.interpreter.trimmingCharacters(in: .whitespacesAndNewlines)
                if step.scriptMode != .file, interpreter.isEmpty {
                    throw ToolDraftError.invalid("Choose an interpreter for the script in step '\(id)'.")
                }
                if !interpreter.isEmpty { payload["interpreter"] = interpreter }
                let arguments = nonEmptyLines(step.arguments)
                if !arguments.isEmpty { payload["arguments"] = arguments }
                let environment = try environmentDefinition(step.environment)
                if !environment.isEmpty { payload["environment"] = environment }
                let directory = step.writeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                if !directory.isEmpty { payload["writeDirectory"] = directory }
                definition["payload"] = ["execute": payload]
            case .think:
                let instruction = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !instruction.isEmpty else {
                    throw ToolDraftError.invalid("Think step '\(id)' needs an instruction.")
                }
                definition["payload"] = ["think": ["instruction": instruction]]
            }
            result.append(definition)
        }
        return result
    }

    private func processDefinition() throws -> [String] {
        let executable = processExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else { throw ToolDraftError.invalid("Choose a program to run.") }
        return [executable] + nonEmptyLines(processArguments)
    }

    private func environmentDefinition(_ value: String) throws -> [String: String] { try pairs(value, separator: "=") }

    private func pairs(_ value: String, separator: Character) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in value.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let split = trimmed.firstIndex(of: separator) else {
                throw ToolDraftError.invalid("Use one \(separator) between each name and value.")
            }
            let key = String(trimmed[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            let item = String(trimmed[trimmed.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw ToolDraftError.invalid("A name cannot be empty.") }
            guard result[key] == nil else {
                throw ToolDraftError.invalid("The name '\(key)' is listed more than once.")
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
        value.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

}
