import AnyLanguageModel
import Foundation
import Hail
import TurgaiApplication

/// How many tokens the object tools take for Apple's on-device model, counted by the model itself:
/// they come out of the same context as the conversation.
enum ToolTokens {
    /// One tool as the model is given it: its name, description and schema.
    private struct Counted: AnyLanguageModel.Tool {
        let name: String
        let description: String
        let parameters: GenerationSchema

        func call(arguments: GeneratedContent) async throws -> String { "" }
    }

    static func report(on node: EvalNode) async throws {
        let session = ObjectSession(actorSystem: node.system, scopes: [.shared])
        let tools = (try await ObjectTools(session: session).tools()).map { tool in
            Counted(name: tool.schema.name, description: tool.schema.description, parameters: tool.schema.parameters)
        }
        let model = AnyLanguageModel.SystemLanguageModel.default
        print("System model: object tools take \(try await model.tokenCount(for: tools)) of \(model.contextSize) tokens")
        for tool in tools {
            print("  \(tool.name): \(try await model.tokenCount(for: [tool]))")
        }
    }
}
