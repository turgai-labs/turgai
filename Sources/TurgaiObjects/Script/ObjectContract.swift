import DiscoverableActors
import Doppel

/// What an object of a type takes, as code meets it: its methods, and the protocols it declares
/// for others to conform to, each with its requirements, every type as Swift resolves it. One for
/// every type, made here or built in: read from what the type describes, through the same
/// declarations code is checked against.
public struct ObjectContract: Sendable, Equatable {
    public let type: ObjectTypeName
    /// What others can ask it, as Swift declares its methods.
    public let methods: [Declarations.Method]
    /// The protocols it declares, by name, each with what a type conforming to it takes.
    public let protocols: [ObjectProtocolName: [Declarations.Method]]

    /// The contract `description` says, as Swift resolves it.
    public init(_ description: ObjectDescription) throws(CodeProblem) {
        let interface = Uses.interface(of: [Uses.Object(description: description, publishes: true)])
        // What it takes doesn't depend on whether it lasts: it's read without `init(id:)`.
        let files = ObjectModule.given(interface, lasting: []).map { SwiftCheck.File(name: $0.name, code: $0.code) }
        let (problems, read) = SwiftCheck.declarations(of: description.type, in: ObjectModule.objectsFile, of: files)
        guard let read, case .actor(_, let methods, _, _)? = read[description.type] else {
            throw CodeProblem(
                "`\(description.type)` can't be read as Swift: \(problems.map(\.message).joined(separator: "; "))")
        }
        type = ObjectTypeName(rawValue: description.type)
        self.methods = methods
        var protocols: [ObjectProtocolName: [Declarations.Method]] = [:]
        for name in description.protocols.keys {
            if case .protocol(let requirements, _)? = read[name] {
                protocols[ObjectProtocolName(rawValue: name)] = requirements
            }
        }
        self.protocols = protocols
    }

    /// Whether it takes every one of `requirements`, as Swift calls each: its name, its
    /// parameters' labels and types, and what it gives back. What a type declares it conforms to
    /// isn't asked: an object conforms by what it takes, whatever its code was written with.
    public func conforms(to requirements: [Declarations.Method]) -> Bool {
        requirements.allSatisfy { requirement in
            methods.contains { method in
                method.name == requirement.name && method.result == requirement.result
                    && method.parameters.map(\.label) == requirement.parameters.map(\.label)
                    && method.parameters.map(\.type) == requirement.parameters.map(\.type)
            }
        }
    }
}
