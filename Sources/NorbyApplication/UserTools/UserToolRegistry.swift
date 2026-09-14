import AnyLanguageModel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Why a spec file did not become a tool. Issues are values reported to the
/// host; a broken spec never crashes the load and never silently passes.
public struct UserToolLoadIssue: Sendable {
    public enum Reason: Sendable {
        case unreadable(String)
        case invalidSpec(String)
        case duplicateName(String)
        case builtinNameCollision(String)
    }

    public let source: URL
    public let reason: Reason
}

/// Loads user tool specs from a directory of JSON files. `load()` re-reads
/// the directory on every call: the tool set is tiny, parsing is
/// microseconds against multi-second turns, and there is no cache to
/// invalidate — adding or deleting a spec file takes effect on the next
/// turn.
public struct UserToolRegistry: Sendable {
    public let directory: URL
    private let report: @Sendable (UserToolLoadIssue) -> Void

    public init(
        directory: URL,
        report: @escaping @Sendable (UserToolLoadIssue) -> Void = { _ in }
    ) {
        self.directory = directory
        self.report = report
    }

    public func reportIssue(_ issue: UserToolLoadIssue) {
        report(issue)
    }

    public func load() -> [UserTool] {
        let files =
            ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []).filter { $0.pathExtension == "json" }

        // Sorted filenames make resolution deterministic; on a name
        // collision the first file wins and the rest are reported.
        var loaded: [UserTool] = []
        var seenNames: Set<String> = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file) else {
                report(.init(source: file, reason: .unreadable("Could not read file.")))
                continue
            }
            do {
                let spec = try JSONDecoder().decode(UserToolSpec.self, from: data)
                let tool = try spec.makeUserTool(source: file)
                guard !seenNames.contains(tool.name) else {
                    report(.init(source: file, reason: .duplicateName(tool.name)))
                    continue
                }
                seenNames.insert(tool.name)
                loaded.append(tool)
            } catch let error as SpecValidationError {
                report(.init(source: file, reason: .invalidSpec(error.message)))
            } catch {
                report(.init(source: file, reason: .invalidSpec(String(describing: error))))
            }
        }
        return loaded
    }
}

/// A spec that failed validation. Private: surfaces only as an
/// `.invalidSpec` load issue.
private struct SpecValidationError: Error {
    let message: String
}

/// The on-disk shape of one tool spec. Decoded and validated once per load;
/// only the validated product (`UserTool`) escapes. `script` is accepted as a
/// legacy spelling for the native `process` body.
struct UserToolSpec: Decodable {
    struct ProcessBody: Decodable {
        var argv: [String]
        var environment: [String: String]?
    }

    struct WasmBody: Decodable {
        var module: String
    }

    struct PromptBody: Decodable {
        var instruction: String
        var agentRole: String?
    }

    var name: String
    var description: String
    var version: Int?
    var approval: UserTool.ApprovalPolicy?
    /// JSON Schema in the dialect `@Generable` emits; decoded directly into
    /// `GenerationSchema`. Absent means a no-argument tool.
    var arguments: GenerationSchema?
    var body: Body

    enum Body: Decodable {
        case process(ProcessBody)
        case wasm(WasmBody)
        case prompt(PromptBody)
        case workflow(UserTool.Workflow)

        private enum CodingKeys: String, CodingKey {
            case kind
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "process", "script":
                self = .process(try ProcessBody(from: decoder))
            case "wasm":
                self = .wasm(try WasmBody(from: decoder))
            case "prompt":
                self = .prompt(try PromptBody(from: decoder))
            case "workflow":
                self = .workflow(try UserTool.Workflow(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container,
                    debugDescription:
                        "Unknown body kind '\(kind)'; expected 'workflow', 'process', 'wasm', or 'prompt'."
                )
            }
        }
    }

    func makeUserTool(source: URL) throws -> UserTool {
        func fail(_ message: String) throws -> Never {
            throw SpecValidationError(message: "Tool '\(name)': \(message)")
        }

        guard !name.isEmpty else { try fail("name must not be empty.") }
        guard !description.isEmpty else { try fail("description must not be empty.") }
        if let version, version != 1 {
            try fail("unsupported spec version \(version); expected version 1.")
        }

        let arguments = arguments ?? Self.emptyArguments
        let argumentNames = Self.argumentNames(of: arguments)

        let resolvedApproval: UserTool.ApprovalPolicy
        let body: UserTool.Body
        switch self.body {
        case .process(let process):
            guard !process.argv.isEmpty else { try fail("process argv must not be empty.") }
            guard let executable = process.argv.first,
                !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { try fail("process argv must start with an executable.") }
            let environmentValues = process.environment.map { Array($0.values) } ?? []
            for value in process.argv + environmentValues {
                for placeholder in UserTool.placeholders(in: value) {
                    guard !placeholder.isEmpty else {
                        try fail("process contains an empty argument placeholder.")
                    }
                    guard argumentNames.contains(placeholder) else {
                        try fail(
                            "process references unknown argument '{{\(placeholder)}}'; declared arguments: "
                                + argumentNames.sorted().joined(separator: ", ") + "."
                        )
                    }
                }
            }
            resolvedApproval = approval ?? .always
            body = .process(
                UserTool.NativeProcess(
                    argv: process.argv,
                    environment: process.environment
                )
            )
        case .wasm(let wasm):
            let modulePath = wasm.module.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modulePath.isEmpty else { try fail("wasm module must not be empty.") }
            guard !modulePath.hasPrefix("/") else {
                try fail("wasm module must be relative to the tool directory.")
            }
            guard URL(fileURLWithPath: modulePath).pathExtension.lowercased() == "wasm" else {
                try fail("wasm module must have a .wasm extension.")
            }
            let toolDirectory = source.deletingLastPathComponent().standardizedFileURL
            let moduleURL =
                toolDirectory
                .appendingPathComponent(modulePath)
                .standardizedFileURL
            let root =
                toolDirectory.path.hasSuffix("/")
                ? toolDirectory.path
                : toolDirectory.path + "/"
            guard moduleURL.path.hasPrefix(root) else {
                try fail("wasm module must stay inside the tool directory.")
            }
            resolvedApproval = approval ?? .always
            body = .wasm(UserTool.Wasm(module: moduleURL))
        case .prompt(let prompt):
            guard !prompt.instruction.isEmpty else { try fail("prompt instruction must not be empty.") }
            for placeholder in UserTool.placeholders(in: prompt.instruction) {
                guard !placeholder.isEmpty else {
                    try fail("prompt contains an empty argument placeholder.")
                }
                guard argumentNames.contains(placeholder) else {
                    try fail(
                        "prompt references unknown argument '{{\(placeholder)}}'; declared arguments: "
                            + argumentNames.sorted().joined(separator: ", ") + "."
                    )
                }
            }
            resolvedApproval = approval ?? .never
            body = .prompt(UserTool.Prompt(instruction: prompt.instruction, agentRole: prompt.agentRole))
        case .workflow(let workflow):
            try Self.validate(workflow, toolName: name)
            // A workflow may contain a fetch or execute stage even when the
            // first version of the UI only displays a harmless-looking name.
            // Keep the safe default at the whole-tool boundary.
            resolvedApproval = approval ?? .always
            body = .workflow(workflow)
        }

        return UserTool(
            name: name,
            description: description,
            approval: resolvedApproval,
            arguments: arguments,
            body: body,
            source: source
        )
    }

    private struct ArgumentOutline: Decodable {
        let type: String?
        let properties: [String: JSONValue]?
    }

    /// Top-level property names of a spec-authored schema. Round-trips the
    /// Codable encoding: `GenerationSchema`'s node types are internal to
    /// AnyLanguageModel, and spec schemas are plain objects with no refs.
    private static func argumentNames(of schema: GenerationSchema) -> Set<String> {
        guard let data = try? JSONEncoder().encode(schema),
            let outline = try? JSONDecoder().decode(ArgumentOutline.self, from: data)
        else { return [] }
        if let properties = outline.properties {
            if !properties.isEmpty { return Set(properties.keys) }
            return outline.type == "object" ? [] : ["value"]
        }
        return ["value"]
    }

    private static let emptyArguments: GenerationSchema = {
        // A compile-time constant; the decode cannot fail.
        try! JSONDecoder().decode(
            GenerationSchema.self,
            from: Data("{\"type\":\"object\",\"properties\":{}}".utf8)
        )
    }()

    private static func validate(
        _ workflow: UserTool.Workflow,
        toolName: String
    ) throws {
        func fail(_ message: String) throws -> Never {
            throw SpecValidationError(message: "Tool '\(toolName)': \(message)")
        }

        guard !workflow.steps.isEmpty else {
            try fail("workflow must contain at least one step.")
        }

        var stepIDs: Set<String> = []
        var outputNames: Set<String> = []
        for (index, step) in workflow.steps.enumerated() {
            let position = index + 1
            let id = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                try fail("workflow step \(position) must have a non-empty id.")
            }
            guard stepIDs.insert(id).inserted else {
                try fail("workflow step id '\(id)' is duplicated.")
            }

            let outputName = step.outputName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !outputName.isEmpty else {
                try fail("workflow step '\(id)' has an empty output name.")
            }
            guard outputNames.insert(outputName).inserted else {
                try fail("workflow output name '\(outputName)' is duplicated.")
            }

            if let inputs = step.inputs {
                for (alias, reference) in inputs {
                    guard !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        try fail("workflow step '\(id)' contains an empty input alias.")
                    }
                    guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        try fail("workflow step '\(id)' contains an empty input reference.")
                    }
                }
            }

            switch step.kind {
            case .fetch:
                guard step.writeDirectory == nil else {
                    try fail("fetch step '\(id)' cannot declare a write directory.")
                }
                guard let url = step.url,
                    !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    try fail("fetch step '\(id)' must have a url.")
                }
                if let method = step.method {
                    guard !method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        !method.contains(where: { $0 == "\r" || $0 == "\n" })
                    else {
                        try fail("fetch step '\(id)' has an invalid method.")
                    }
                }
                if let hosts = step.allowedHosts {
                    for host in hosts {
                        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalized.isEmpty,
                            !normalized.contains(where: { $0.isWhitespace }),
                            !normalized.contains("/"),
                            !normalized.contains(":")
                        else {
                            try fail("fetch step '\(id)' has an invalid allowed host '\(host)'.")
                        }
                    }
                }

            case .execute:
                guard step.allowedHosts == nil else {
                    try fail("execute step '\(id)' cannot declare allowed hosts.")
                }
                guard (step.script != nil) != (step.scriptSource != nil) else {
                    try fail("execute step '\(id)' must specify exactly one of script or scriptSource.")
                }
                guard
                    step.scriptSource != nil
                        || (step.script?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                else {
                    try fail("execute step '\(id)' must have a script path.")
                }
                if let script = step.script {
                    guard !script.hasPrefix("/") else {
                        try fail("execute step '\(id)' script must be relative to the tool directory.")
                    }
                    let scriptURL = URL(fileURLWithPath: script)
                    guard !scriptURL.pathComponents.contains("..") else {
                        try fail("execute step '\(id)' script cannot contain '..'.")
                    }
                }
                if let writeDirectory = step.writeDirectory {
                    let trimmed = writeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                        !trimmed.hasPrefix("/"),
                        !URL(fileURLWithPath: trimmed).pathComponents.contains("..")
                    else {
                        try fail(
                            "execute step '\(id)' writeDirectory must be a relative path inside the workspace."
                        )
                    }
                }
                if let source = step.scriptSource {
                    guard !source.isEmpty else {
                        try fail("execute step '\(id)' scriptSource must not be empty.")
                    }
                }
                if let interpreter = step.interpreter {
                    guard !interpreter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        try fail("execute step '\(id)' has an empty interpreter.")
                    }
                }
                if let arguments = step.arguments {
                    guard !arguments.contains(where: { $0.isEmpty }) else {
                        try fail("execute step '\(id)' contains an empty argument.")
                    }
                }

            case .think:
                guard step.allowedHosts == nil else {
                    try fail("think step '\(id)' cannot declare allowed hosts.")
                }
                guard step.writeDirectory == nil else {
                    try fail("think step '\(id)' cannot declare a write directory.")
                }
                guard let instruction = step.instruction,
                    !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    try fail("think step '\(id)' must have an instruction.")
                }
                if let agentRole = step.agentRole {
                    guard agentRole == "user-tool" else {
                        try fail("think step '\(id)' may only use the 'user-tool' agent role.")
                    }
                }
            }

        }
    }
}
