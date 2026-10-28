import AnyLanguageModel
import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A user-authored tool, loaded from a spec file under `.turgai/tools/` and
/// validated before it can be addressed by the model. The spec is data, not
/// code: name, description, an argument schema in the same JSON Schema
/// dialect `@Generable` emits, and a body that is a workflow, native process,
/// Wasm module, or sub-agent prompt.
public struct UserTool: Sendable {
    public struct NativeProcess: Sendable {
        /// Executable followed by argv. Each element may contain a declared
        /// `{{argument}}` placeholder; no shell parsing is performed.
        public let argv: [String]
        /// `nil` preserves the host process environment. A value replaces it
        /// with exactly the supplied environment.
        public let environment: [String: String]?

        public init(argv: [String], environment: [String: String]? = nil) {
            self.argv = argv
            self.environment = environment
        }
    }

    public struct Wasm: Sendable {
        /// The module is resolved under the directory containing the tool
        /// spec. It is never treated as a native executable or shell script.
        public let module: URL

        public init(module: URL) {
            self.module = module
        }
    }

    public struct Prompt: Sendable {
        /// Instruction template with `{{name}}` placeholders, delegated to a
        /// spawned sub-agent.
        public var instruction: String
        public var agentRole: String?

        public init(instruction: String, agentRole: String? = nil) {
            self.instruction = instruction
            self.agentRole = agentRole
        }
    }

    /// A user-facing sequence of stages. The stored representation deliberately
    /// uses verbs (`fetch`, `execute`, and `think`) rather than Hail effect
    /// names. Turgai resolves and runs one concrete effect for each stage at
    /// execution time, passing named outputs to later stages.
    public struct Workflow: Sendable, Equatable, Codable {
        public let steps: [WorkflowStep]

        public init(steps: [WorkflowStep]) {
            self.steps = steps
        }
    }

    /// One stage in a user-authored workflow. Fields not used by the selected
    /// kind are required to remain nil; the registry validates that invariant
    /// before the workflow reaches the model-facing tool set.
    public struct WorkflowStep: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Equatable, Codable {
            case fetch
            case execute
            case think
        }

        /// Additional permission for this stage. `.inherit` keeps the lane
        /// authority as the upper bound and adds no restriction; `.denied`
        /// closes this stage; `.allowed` records an explicit grant that still
        /// cannot override a lane denial.
        public enum Permission: String, Sendable, Equatable, Codable {
            case inherit
            case allowed
            case denied
        }

        public let id: String
        public let saveAs: String?
        public let permission: Permission
        public let inputs: [String: String]?
        public let payload: Payload

        public enum Payload: Sendable, Equatable, Codable {
            public struct Fetch: Sendable, Equatable, Codable {
                public let url: String
                public let method: String?
                public let headers: [String: String]?
                public let body: String?
                public let allowedHosts: [String]?

                public init(
                    url: String,
                    method: String? = nil,
                    headers: [String: String]? = nil,
                    body: String? = nil,
                    allowedHosts: [String]? = nil
                ) {
                    self.url = url
                    self.method = method
                    self.headers = headers
                    self.body = body
                    self.allowedHosts = allowedHosts
                }
            }

            public enum Script: Sendable, Equatable, Codable {
                case path(String)
                case inline(String)

                private enum CodingKeys: String, CodingKey {
                    case path
                    case inline
                }

                public init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    if values.contains(.path) {
                        self = .path(try values.decode(String.self, forKey: .path))
                    } else if values.contains(.inline) {
                        self = .inline(try values.decode(String.self, forKey: .inline))
                    } else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .path,
                            in: values,
                            debugDescription: "A script must contain path or inline source."
                        )
                    }
                }

                public func encode(to encoder: Encoder) throws {
                    var values = encoder.container(keyedBy: CodingKeys.self)
                    switch self {
                    case .path(let path): try values.encode(path, forKey: .path)
                    case .inline(let source): try values.encode(source, forKey: .inline)
                    }
                }
            }

            public struct Execute: Sendable, Equatable, Codable {
                public let script: Script
                public let interpreter: String?
                public let arguments: [String]?
                public let environment: [String: String]?
                public let writeDirectory: String?

                public init(
                    script: Script,
                    interpreter: String? = nil,
                    arguments: [String]? = nil,
                    environment: [String: String]? = nil,
                    writeDirectory: String? = nil
                ) {
                    self.script = script
                    self.interpreter = interpreter
                    self.arguments = arguments
                    self.environment = environment
                    self.writeDirectory = writeDirectory
                }
            }

            public struct Think: Sendable, Equatable, Codable {
                public let instruction: String
                public let agentRole: String?

                public init(instruction: String, agentRole: String? = nil) {
                    self.instruction = instruction
                    self.agentRole = agentRole
                }
            }

            case fetch(Fetch)
            case execute(Execute)
            case think(Think)

            private enum CodingKeys: String, CodingKey {
                case fetch
                case execute
                case think
            }

            public init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                if values.contains(.fetch) {
                    self = .fetch(try values.decode(Fetch.self, forKey: .fetch))
                } else if values.contains(.execute) {
                    self = .execute(try values.decode(Execute.self, forKey: .execute))
                } else if values.contains(.think) {
                    self = .think(try values.decode(Think.self, forKey: .think))
                } else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .fetch,
                        in: values,
                        debugDescription: "A workflow payload must be fetch, execute, or think."
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .fetch(let fetch): try values.encode(fetch, forKey: .fetch)
                case .execute(let execute): try values.encode(execute, forKey: .execute)
                case .think(let think): try values.encode(think, forKey: .think)
                }
            }
        }

        public init(
            id: String,
            saveAs: String? = nil,
            permission: Permission = .inherit,
            inputs: [String: String]? = nil,
            payload: Payload
        ) {
            self.id = id
            self.saveAs = saveAs
            self.permission = permission
            self.inputs = inputs
            self.payload = payload
        }

        public var kind: Kind {
            switch payload {
            case .fetch: return .fetch
            case .execute: return .execute
            case .think: return .think
            }
        }
        public var allowedHosts: [String]? {
            guard case .fetch(let fetch) = payload else { return nil }
            return fetch.allowedHosts
        }
        public var writeDirectory: String? {
            guard case .execute(let execute) = payload else { return nil }
            return execute.writeDirectory
        }
        public var url: String? {
            guard case .fetch(let fetch) = payload else { return nil }
            return fetch.url
        }
        public var method: String? {
            guard case .fetch(let fetch) = payload else { return nil }
            return fetch.method
        }
        public var headers: [String: String]? {
            guard case .fetch(let fetch) = payload else { return nil }
            return fetch.headers
        }
        public var body: String? {
            guard case .fetch(let fetch) = payload else { return nil }
            return fetch.body
        }
        public var script: String? {
            guard case .execute(let execute) = payload,
                case .path(let path) = execute.script
            else { return nil }
            return path
        }
        public var scriptSource: String? {
            guard case .execute(let execute) = payload,
                case .inline(let source) = execute.script
            else { return nil }
            return source
        }
        public var interpreter: String? {
            guard case .execute(let execute) = payload else { return nil }
            return execute.interpreter
        }
        public var arguments: [String]? {
            guard case .execute(let execute) = payload else { return nil }
            return execute.arguments
        }
        public var environment: [String: String]? {
            guard case .execute(let execute) = payload else { return nil }
            return execute.environment
        }
        public var instruction: String? {
            guard case .think(let think) = payload else { return nil }
            return think.instruction
        }
        public var agentRole: String? {
            guard case .think(let think) = payload else { return nil }
            return think.agentRole
        }

        public var outputName: String { saveAs ?? id }
    }

    public enum Body: Sendable {
        case process(NativeProcess)
        case wasm(Wasm)
        case prompt(Prompt)
        case workflow(Workflow)
    }

    public let name: String
    public let description: String
    public let arguments: GenerationSchema
    public let body: Body
    /// The spec file this tool was loaded from, for diagnostics and for re-validation before it
    /// runs.
    public let source: URL

    public init(
        name: String,
        description: String,
        arguments: GenerationSchema,
        body: Body,
        source: URL
    ) {
        self.name = name
        self.description = description
        self.arguments = arguments
        self.body = body
        self.source = source
    }

    /// The argument names a `{{placeholder}}` may reference, read from the
    /// schema's top-level properties. `GenerationSchema`'s node types are
    /// internal to AnyLanguageModel, so the outline goes through the Codable
    /// representation; spec-authored schemas are plain objects with no refs.
    public var argumentNames: [String] {
        struct Outline: Decodable {
            let type: String?
            let properties: [String: JSONValue]?
        }
        guard let data = try? JSONEncoder().encode(arguments),
            let outline = try? JSONDecoder().decode(Outline.self, from: data)
        else { return [] }
        if let properties = outline.properties {
            if !properties.isEmpty { return properties.keys.sorted() }
            return outline.type == "object" ? [] : ["value"]
        }
        return ["value"]
    }

    /// Renders the prompt instruction template against decoded arguments.
    public func renderPrompt(_ content: GeneratedContent) throws -> String {
        guard case .prompt(let prompt) = body else {
            throw ToolError.invalidArgument("body", value: "not a prompt")
        }
        let values = try Self.argumentValues(from: content)
        return try Self.render(prompt.instruction, values: values)
    }

    /// Renders a native process argv template against decoded arguments.
    /// The first element is the executable; the rest are ordinary argv
    /// values. It is never passed through a shell implicitly.
    public func renderProcess(_ content: GeneratedContent) throws -> [String] {
        guard case .process(let process) = body else {
            throw ToolError.invalidArgument("body", value: "not a process")
        }
        let values = try Self.argumentValues(from: content)
        let argv = try process.argv.map { try Self.render($0, values: values) }
        guard let executable = argv.first, !executable.isEmpty else {
            throw ToolError.invalidArgument("argv", value: "empty")
        }
        return argv
    }

    /// Renders environment values for a native process. Environment keys are
    /// literal; values may use the same declared argument placeholders.
    public func renderProcessEnvironment(
        _ content: GeneratedContent
    ) throws -> [String: String]? {
        guard case .process(let process) = body else {
            throw ToolError.invalidArgument("body", value: "not a process")
        }
        guard let environment = process.environment else { return nil }
        let values = try Self.argumentValues(from: content)
        return try environment.mapValues { try Self.render($0, values: values) }
    }

    // MARK: - Templates

    static func placeholders(in template: String) -> [String] {
        var result: [String] = []
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "}}") else { break }
            result.append(
                String(rest[rest.startIndex..<close.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            rest = rest[close.upperBound...]
        }
        return result
    }

    private static func render(_ template: String, values: [String: GeneratedContent]) throws -> String {
        var rendered = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            rendered += rest[rest.startIndex..<open.lowerBound]
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "}}") else {
                rendered += "{{"
                rendered += rest
                return rendered
            }
            let key = String(rest[rest.startIndex..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw ToolError.invalidArgument("template", value: "empty placeholder")
            }
            guard let value = values[key] else {
                throw ToolError.missingArgument(key)
            }
            rendered += stringValue(of: value)
            rest = rest[close.upperBound...]
        }
        rendered += rest
        return rendered
    }

    static func argumentValues(from content: GeneratedContent) throws -> [String: GeneratedContent] {
        guard case .structure(let properties, _) = content.kind else {
            // Scalar arguments (a tool whose schema is a bare string) are
            // addressable as {{value}}.
            return content.kind == .null ? [:] : ["value": content]
        }
        return properties
    }

    static func stringValue(of content: GeneratedContent) -> String {
        switch content.kind {
        case .string(let value): value
        case .number(let value):
            value == value.rounded() ? String(Int(value)) : String(describing: value)
        case .bool(let value): value ? "true" : "false"
        case .null: ""
        case .structure, .array: content.jsonString
        }
    }
}
