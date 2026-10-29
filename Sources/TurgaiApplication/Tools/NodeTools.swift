import AnyLanguageModel
import DiscoverableActors
import DistributedCluster
import Hail
import TurgaiDomain
import TurgaiObjects

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The tools every node has, as a turn offers them to the model and as object code calls them: the
/// same commands, each call from code decided by the node's authority, as a turn's are.
public struct NodeTools: Sendable {
    public let http: Http
    public let search: Search
    public let chat: Chat
    /// The authority of the node a call from code runs on.
    private let authority: @Sendable (ClusterSystem) -> any Authority

    public init(
        searchBackend: WebSearchBackend = .duckDuckGo, authority: @escaping @Sendable (ClusterSystem) -> any Authority
    ) {
        self.http = Http()
        self.search = Search(backend: searchBackend)
        self.chat = Chat()
        self.authority = authority
    }

    /// The commands a turn offers the model.
    public var turn: [any HailCore.Tool] { http.tools + search.tools }

    /// What object code calls: each tool by its type's name, with the commands whose input and
    /// output code can hold. The chat is code's alone: a turn's model answers in it already.
    public var api: ToolsAPI {
        ToolsAPI(tools: [
            ToolsAPI.Tool(
                name: "\(Http.self)", description: http.group.description, functions: functions(http.commands)),
            ToolsAPI.Tool(
                name: "\(Search.self)", description: search.group.description, functions: functions(search.commands)),
            ToolsAPI.Tool(
                name: "\(Chat.self)", description: chat.group.description, functions: functions(chat.commands)),
        ])
    }

    /// Each command code can call, by its name.
    private func functions(_ commands: [String: any HailCore.Tool]) -> [ToolsAPI.Function] {
        commands.sorted { $0.key < $1.key }.compactMap { name, command in
            Self.function(name, command, authority: authority)
        }
    }

    /// A command as code calls it: given the value its input is, as the model's call gives it, run
    /// with the authority of the node, and giving back its output as `Codable` writes it. `nil` for
    /// one whose input or output has no schema code's values are written from.
    static func function<Command: HailCore.Tool>(
        _ name: String, _ command: Command, authority: @escaping @Sendable (ClusterSystem) -> any Authority
    ) -> ToolsAPI.Function? {
        guard let input = Command.Input.self as? any Describable.Type,
            let output = Command.Effect.Output.self as? any (Describable & Encodable).Type
        else { return nil }
        return ToolsAPI.Function(
            name: name, description: command.description, input: input.jsonSchema, output: output.jsonSchema
        ) { value, node in
            let written = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            let effect = try command.effect(for: try Command.Input(try GeneratedContent(json: written)))
            let answer = try await withEffect(effect, authority: authority(node)) { token in
                try await Command.Effect.run(in: token)
            }
            guard let encodable = answer as? any Encodable else { throw NotEncodable(command: name) }
            return try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(encodable))
        }
    }
}

/// A command's output that `Codable` can't write, which code is given no other way.
struct NotEncodable: Error, CustomStringConvertible {
    let command: String

    var description: String { "`\(command)` gave back what can't be written" }
}
