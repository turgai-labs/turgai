import SwiftParser
import SwiftSyntax

/// The module an object's code imports, as Swift writes it: its declarations, which the code is
/// checked and run against.
public struct ModuleInterface: Codable, Sendable, Equatable {
    public let name: String
    /// Its declarations, as Swift writes them.
    public let source: String

    public init(name: String, source: String) {
        self.name = name
        self.source = source
    }
}

extension ModuleInterface {
    /// The names of the structs and enums it declares: the values its objects send and take.
    public var valueTypes: Set<String> {
        Set(Parser.parse(source: source).statements.compactMap { statement in
            statement.item.as(StructDeclSyntax.self)?.name.text ?? statement.item.as(EnumDeclSyntax.self)?.name.text
        })
    }
}

extension ModuleInterface {
    /// The actors it declares, each with what it takes, publishes and announces: a function marked
    /// with one of `events` is an event the actor announces.
    public func actors(events: Set<String>) -> [DeclaredActor] {
        Parser.parse(source: source).statements.compactMap { statement in
            statement.item.as(ActorDeclSyntax.self).map { DeclaredActor($0, events: events) }
        }
    }
}

/// An actor a module declares, as its interface shows it: what it takes, what it publishes, and
/// what it announces, each as Swift writes it.
public struct DeclaredActor: Sendable {
    /// A method or event, as declared: its parameters, what it returns, and its effects.
    public struct Method: Sendable, Equatable {
        public struct Parameter: Sendable, Equatable {
            /// What it's called with: `nil` for `_`.
            public let label: String?
            public let name: String
            public let type: String
        }

        public let parameters: [Parameter]
        public let returns: String?
        /// `async throws`, as written.
        public let effects: String?
    }

    public let name: String
    public let methods: [String: Method]
    /// What it publishes to be read, by name, with each one's type.
    public let properties: [String: String]
    public let events: [String: Method]

    init(_ declaration: ActorDeclSyntax, events marks: Set<String>) {
        var methods: [String: Method] = [:]
        var properties: [String: String] = [:]
        var events: [String: Method] = [:]
        for member in declaration.memberBlock.members {
            if let function = member.decl.as(FunctionDeclSyntax.self) {
                let method = Method(
                    parameters: function.signature.parameterClause.parameters.map { parameter in
                        Method.Parameter(
                            label: parameter.firstName.text == "_" ? nil : parameter.firstName.text,
                            name: (parameter.secondName ?? parameter.firstName).text, type: parameter.type.trimmedDescription)
                    },
                    returns: function.signature.returnClause?.type.trimmedDescription,
                    effects: function.signature.effectSpecifiers?.trimmedDescription)
                let isEvent = function.attributes.contains { attribute in
                    attribute.as(AttributeSyntax.self).map { marks.contains($0.attributeName.trimmedDescription) } ?? false
                }
                if isEvent { events[function.name.text] = method } else { methods[function.name.text] = method }
            } else if let variable = member.decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    if let type = binding.typeAnnotation?.type { properties[binding.pattern.trimmedDescription] = type.trimmedDescription }
                }
            }
        }
        self.name = declaration.name.text
        self.methods = methods
        self.properties = properties
        self.events = events
    }
}
