import DiscoverableActors
import DistributedCluster
import TurgaiDomain

/// The tools object code calls, the same on every node: `Tools.Http.send`. Each runs where the
/// code runs, in the chain of the call that runs it, and takes and gives values of the types its
/// schemas name.
public struct ToolsAPI: Sendable {
    /// One tool, `Tools.Http`: what it's for, and its functions.
    public struct Tool: Sendable {
        public let name: String
        public let description: String?
        public let functions: [Function]

        public init(name: String, description: String?, functions: [Function]) {
            self.name = name
            self.description = description
            self.functions = functions
        }
    }

    /// One of a tool's functions, `send`: what it's for, the value it takes and the value it gives,
    /// each as its schema names its type, and how it runs on a node.
    public struct Function: Sendable {
        public let name: String
        public let description: String?
        public let input: JSONValue
        public let output: JSONValue
        let run: @Sendable (_ input: JSONValue, _ node: ClusterSystem) async throws -> JSONValue

        public init(
            name: String, description: String?, input: JSONValue, output: JSONValue,
            run: @escaping @Sendable (_ input: JSONValue, _ node: ClusterSystem) async throws -> JSONValue
        ) {
            self.name = name
            self.description = description
            self.input = input
            self.output = output
            self.run = run
        }
    }

    public let tools: [Tool]

    public init(tools: [Tool] = []) {
        self.tools = tools
    }

    /// Runs the function code called, with the value it gave, on `node`, in the current chain.
    public func call(_ name: ToolFunctionName, with input: JSONValue, on node: ClusterSystem) async throws -> JSONValue
    {
        guard
            let function = tools.first(where: { $0.name == name.tool })?.functions.first(where: {
                $0.name == name.function
            })
        else { throw NoSuchTool(name: name) }
        return try await function.run(input, node)
    }
}

/// A function of a tool, as code names it: `Tools.Http.send`.
public struct ToolFunctionName: Hashable, Sendable, CustomStringConvertible {
    public let tool: String
    public let function: String

    public init(tool: String, function: String) {
        self.tool = tool
        self.function = function
    }

    /// The function a qualified name is, `Tools.Http.send`; `nil` for one that isn't a tool's.
    public init?(qualified: String) {
        let parts = qualified.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == Uses.tools, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        self.init(tool: parts[1], function: parts[2])
    }

    public var description: String { "\(Uses.tools).\(tool).\(function)" }
}

/// A function code called that no tool of this node has.
public struct NoSuchTool: Error, Sendable, Equatable, CustomStringConvertible {
    public let name: ToolFunctionName

    public var description: String { "this node has no `\(name)`" }
}

/// Gives every actor on a node the tools object code calls there.
public struct ToolsAPIPlugin: Plugin {
    static let pluginKey: Key = "$turgaiToolsAPI"

    public let api: ToolsAPI

    public init(_ api: ToolsAPI) {
        self.api = api
    }

    public var key: Key { Self.pluginKey }

    public func start(_ system: ClusterSystem) async throws {}

    public func stop(_ system: ClusterSystem) async {}
}

extension ClusterSystem {
    /// The tools object code calls on this node: none when the node has none installed.
    public var toolsAPI: ToolsAPI {
        settings.plugins[ToolsAPIPlugin.pluginKey]?.api ?? ToolsAPI()
    }
}
