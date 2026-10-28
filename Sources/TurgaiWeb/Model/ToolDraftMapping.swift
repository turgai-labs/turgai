import AnyLanguageModel
import TurgaiApplication

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension TurgaiToolDraft {
    init(document: UserToolDocument) {
        self.fileName = document.fileName
        self.kind = .existing
        self.name = document.tool?.name ?? ""
        self.description = document.tool?.description ?? ""
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
                process.environment ?? [:], separator: "="
            )
        case .prompt(let prompt):
            self.bodyKind = .prompt
            self.promptInstruction = prompt.instruction
        case .wasm(let wasm):
            self.bodyKind = .wasm
            self.wasmModule = Self.relativeModulePath(wasm.module, source: tool.source)
        }
    }

    init(form: [String: [String]], fileName: String, kind: ToolDraftKind) {
        self.fileName = fileName
        self.kind = kind
        self.name = form["toolName"]?.first ?? ""
        self.description = form["toolDescription"]?.first ?? ""
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

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
