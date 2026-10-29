import AnyLanguageModel
import TurgaiApplication
import TurgaiDomain

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
    var bodyKind: TurgaiToolBodyKind
    var arguments: [TurgaiToolArgumentDraft]
    var workflowSteps: [TurgaiWorkflowStepDraft]
    var processExecutable: String
    var processArguments: String
    var processEnvironment: String
    var wasmModule: String
    var promptInstruction: String

    static func new(fileName: String) -> Self {
        var draft = Self(
            fileName: fileName,
            kind: .new,
            name: "",
            description: "",
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
        let trimmedName = name.trimmed()
        guard !trimmedName.isEmpty else { throw ToolDraftError.invalid("Give the tool a name.") }
        let trimmedDescription = description.trimmed()
        guard !trimmedDescription.isEmpty else { throw ToolDraftError.invalid("Describe what the tool does.") }
        var root: [String: JSONValue] = [
            "version": 1,
            "name": .string(trimmedName),
            "description": .string(trimmedDescription),
            "arguments": .object(try argumentSchema()),
        ]

        switch bodyKind {
        case .workflow:
            root["body"] = ["kind": "workflow", "steps": .array(try workflowDefinition().map(JSONValue.object))]
        case .process:
            root["body"] = [
                "kind": "process",
                "argv": .array(try processDefinition().map(JSONValue.string)),
                "environment": .object(try environmentDefinition(processEnvironment).mapValues(JSONValue.string)),
            ]
        case .prompt:
            let instruction = promptInstruction.trimmed()
            guard !instruction.isEmpty else { throw ToolDraftError.invalid("Write the instruction for the other bot.") }
            root["body"] = ["kind": "prompt", "instruction": .string(instruction)]
        case .wasm:
            let module = wasmModule.trimmed()
            guard !module.isEmpty, !module.hasPrefix("/"), module.hasSuffix(".wasm") else {
                throw ToolDraftError.invalid("Choose a relative .wasm module.")
            }
            root["body"] = ["kind": "wasm", "module": .string(module)]
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(JSONValue.object(root))
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw ToolDraftError.invalid("The tool could not be prepared for saving.")
        }
    }

    private func argumentSchema() throws -> [String: JSONValue] {
        var properties: [String: JSONValue] = [:]
        var required: [String] = []
        var names: Set<String> = []
        for argument in arguments {
            let name = argument.name.trimmed()
            if name.isEmpty, argument.description.trimmed().isEmpty { continue }
            guard !name.isEmpty else { throw ToolDraftError.invalid("Every input needs a name.") }
            guard names.insert(name).inserted else {
                throw ToolDraftError.invalid("Input '\(name)' is listed more than once.")
            }
            var property: [String: JSONValue] = ["type": .string(argument.type.rawValue)]
            let description = argument.description.trimmed()
            if !description.isEmpty { property["description"] = .string(description) }
            properties[name] = .object(property)
            if argument.required { required.append(name) }
        }
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return schema
    }

    private func workflowDefinition() throws -> [[String: JSONValue]] {
        let activeSteps = workflowSteps.filter { step in
            !step.id.trimmed().isEmpty
                || !step.url.trimmed().isEmpty
                || !step.scriptSource.trimmed().isEmpty
                || !step.scriptFile.trimmed().isEmpty
                || !step.instruction.trimmed().isEmpty
        }
        guard !activeSteps.isEmpty else { throw ToolDraftError.invalid("Add at least one workflow step.") }
        var result: [[String: JSONValue]] = []
        for (index, step) in activeSteps.enumerated() {
            let id = step.id.trimmed()
            guard !id.isEmpty else { throw ToolDraftError.invalid("Step \(index + 1) needs a name.") }
            var definition: [String: JSONValue] = [
                "id": .string(id), "permission": .string(step.permission.rawValue),
            ]
            let saveAs = step.saveAs.trimmed()
            if !saveAs.isEmpty { definition["saveAs"] = .string(saveAs) }
            let inputs = try pairs(step.inputs, separator: "=")
            if !inputs.isEmpty { definition["inputs"] = .object(inputs.mapValues(JSONValue.string)) }
            switch step.kind {
            case .fetch:
                var payload: [String: JSONValue] = [:]
                let url = step.url.trimmed()
                guard !url.isEmpty else { throw ToolDraftError.invalid("Fetch step '\(id)' needs a URL.") }
                payload["url"] = .string(url)
                let method = step.method.trimmed()
                if !method.isEmpty { payload["method"] = .string(method.uppercased()) }
                if let hosts = commaList(step.allowedHosts) { payload["allowedHosts"] = .array(hosts.map(JSONValue.string)) }
                let headers = try pairs(step.headers, separator: ":")
                if !headers.isEmpty { payload["headers"] = .object(headers.mapValues(JSONValue.string)) }
                let body = step.body.trimmed()
                if !body.isEmpty { payload["body"] = .string(body) }
                definition["payload"] = ["fetch": .object(payload)]
            case .execute:
                var payload: [String: JSONValue] = [:]
                let source = step.scriptSource.trimmed()
                let file = step.scriptFile.trimmed()
                if step.scriptMode == .file {
                    guard !file.isEmpty else {
                        throw ToolDraftError.invalid("Execute step '\(id)' needs a script file.")
                    }
                    payload["script"] = ["path": .string(file)]
                } else {
                    guard !source.isEmpty else { throw ToolDraftError.invalid("Execute step '\(id)' needs a script.") }
                    payload["script"] = ["inline": .string(source)]
                }
                let interpreter = step.interpreter.trimmed()
                if step.scriptMode != .file, interpreter.isEmpty {
                    throw ToolDraftError.invalid("Choose an interpreter for the script in step '\(id)'.")
                }
                if !interpreter.isEmpty { payload["interpreter"] = .string(interpreter) }
                let arguments = nonEmptyLines(step.arguments)
                if !arguments.isEmpty { payload["arguments"] = .array(arguments.map(JSONValue.string)) }
                let environment = try environmentDefinition(step.environment)
                if !environment.isEmpty { payload["environment"] = .object(environment.mapValues(JSONValue.string)) }
                let directory = step.writeDirectory.trimmed()
                if !directory.isEmpty { payload["writeDirectory"] = .string(directory) }
                definition["payload"] = ["execute": .object(payload)]
            case .think:
                let instruction = step.instruction.trimmed()
                guard !instruction.isEmpty else {
                    throw ToolDraftError.invalid("Think step '\(id)' needs an instruction.")
                }
                definition["payload"] = ["think": ["instruction": .string(instruction)]]
            }
            result.append(definition)
        }
        return result
    }

    private func processDefinition() throws -> [String] {
        let executable = processExecutable.trimmed()
        guard !executable.isEmpty else { throw ToolDraftError.invalid("Choose a program to run.") }
        return [executable] + nonEmptyLines(processArguments)
    }

    private func environmentDefinition(_ value: String) throws -> [String: String] { try pairs(value, separator: "=") }

    private func pairs(_ value: String, separator: Character) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in value.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmed()
            guard !trimmed.isEmpty else { continue }
            guard let split = trimmed.firstIndex(of: separator) else {
                throw ToolDraftError.invalid("Use one \(separator) between each name and value.")
            }
            let key = String(trimmed[..<split]).trimmed()
            let item = String(trimmed[trimmed.index(after: split)...]).trimmed()
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
            let value = part.trimmed()
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
        return values.isEmpty ? nil : values
    }

    private func nonEmptyLines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline).map { String($0).trimmed() }
            .filter { !$0.isEmpty }
    }

}
