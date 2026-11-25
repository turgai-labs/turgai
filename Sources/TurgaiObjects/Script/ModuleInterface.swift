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
        Set(valueDeclarations.map(\.name))
    }

    /// The structs and enums it declares, in order, each named as Swift names it: a nested one
    /// with the types it's in, `RefundDesk.Refund`, whether it's declared in them or in an
    /// extension of them. An enum with no cases holds no value: it's only a namespace, `Tools`,
    /// whose values are listed and it isn't.
    public var valueDeclarations: [(name: String, declaration: DeclSyntax)] {
        var found: [(name: String, declaration: DeclSyntax)] = []
        func walk(_ declaration: DeclSyntax, in outer: String?) {
            let name: String
            let members: MemberBlockSyntax
            if let structure = declaration.as(StructDeclSyntax.self) {
                (name, members) = (structure.name.text, structure.memberBlock)
            } else if let enumeration = declaration.as(EnumDeclSyntax.self) {
                (name, members) = (enumeration.name.text, enumeration.memberBlock)
            } else if let actor = declaration.as(ActorDeclSyntax.self) {
                for member in actor.memberBlock.members { walk(member.decl, in: actor.name.text) }
                return
            } else if let extended = declaration.as(ExtensionDeclSyntax.self) {
                for member in extended.memberBlock.members {
                    walk(member.decl, in: extended.extendedType.trimmedDescription)
                }
                return
            } else {
                return
            }
            let qualified = outer.map { "\($0).\(name)" } ?? name
            let namespace =
                declaration.is(EnumDeclSyntax.self)
                && !members.members.contains { $0.decl.is(EnumCaseDeclSyntax.self) }
            if !namespace { found.append((qualified, declaration)) }
            for member in members.members { walk(member.decl, in: qualified) }
        }
        for statement in Parser.parse(source: source).statements {
            if let declaration = statement.item.as(DeclSyntax.self) { walk(declaration, in: nil) }
        }
        return found
    }
}

extension ModuleInterface {
    /// The protocols it declares for any object to conform to, in order: those of no actor. One
    /// an actor declares is that actor's, said with it.
    public var protocolDeclarations: [ProtocolDeclSyntax] {
        Parser.parse(source: source).statements.compactMap { $0.item.as(ProtocolDeclSyntax.self) }
    }

    /// The actors it declares, each with what it takes, publishes and announces: a function marked
    /// with one of `events` is an event the actor announces.
    public func actors(events: Set<String>) -> [DeclaredActor] {
        Parser.parse(source: source).statements.compactMap { statement in
            statement.item.as(ActorDeclSyntax.self).map { DeclaredActor($0, events: events) }
        }
    }
}

/// An actor a module declares, as its interface shows it: what it takes, what it publishes, what
/// it announces, and the protocols it declares, each as Swift writes it.
public struct DeclaredActor: Sendable {
    /// A method, as declared: its parameters, what it returns, and its effects.
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

    /// An event it announces: a struct or an enum declared in it, marked `@Event`, whose values
    /// its subscribers are sent.
    public struct Event: Sendable, Equatable {
        /// The type's name in the actor, which is the event's: `RaiseApproved`.
        public let name: String
        /// What a value of it holds, in a line: a struct's fields, `RaiseApproved(amount: Int)`, or
        /// an enum's cases, `Raise: .approved(amount: Int) | .denied`.
        public let written: String
    }

    public let name: String
    public let methods: [String: Method]
    /// What it publishes to be read, by name, with each one's type.
    public let properties: [String: String]
    public let events: [String: Event]
    /// The protocols it declares, by the name code writes them with, `Shop.RefundManager`: each
    /// requirement, by name.
    public let protocols: [String: [String: Method]]

    init(_ declaration: ActorDeclSyntax, events marks: Set<String>) {
        var methods: [String: Method] = [:]
        var properties: [String: String] = [:]
        var events: [String: Event] = [:]
        var protocols: [String: [String: Method]] = [:]
        func method(_ function: FunctionDeclSyntax) -> Method {
            Method(
                parameters: function.signature.parameterClause.parameters.map { parameter in
                    Method.Parameter(
                        label: parameter.firstName.text == "_" ? nil : parameter.firstName.text,
                        name: (parameter.secondName ?? parameter.firstName).text,
                        type: parameter.type.trimmedDescription)
                },
                returns: function.signature.returnClause?.type.trimmedDescription,
                effects: function.signature.effectSpecifiers?.trimmedDescription)
        }
        func marked(_ attributes: AttributeListSyntax) -> Bool {
            attributes.contains { attribute in
                attribute.as(AttributeSyntax.self).map { marks.contains($0.attributeName.trimmedDescription) } ?? false
            }
        }
        for member in declaration.memberBlock.members {
            if let event = member.decl.as(StructDeclSyntax.self), marked(event.attributes) {
                events[event.name.text] = Event(name: event.name.text, written: Self.written(event))
            } else if let event = member.decl.as(EnumDeclSyntax.self), marked(event.attributes) {
                events[event.name.text] = Event(name: event.name.text, written: Self.written(event))
            } else if let nested = member.decl.as(ProtocolDeclSyntax.self) {
                var requirements: [String: Method] = [:]
                for requirement in nested.memberBlock.members.compactMap({ $0.decl.as(FunctionDeclSyntax.self) }) {
                    requirements[requirement.name.text] = method(requirement)
                }
                protocols["\(declaration.name.text).\(nested.name.text)"] = requirements
            } else if let function = member.decl.as(FunctionDeclSyntax.self) {
                methods[function.name.text] = method(function)
            } else if let variable = member.decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    if let type = binding.typeAnnotation?.type {
                        properties[binding.pattern.trimmedDescription] = type.trimmedDescription
                    }
                }
            }
        }
        self.name = declaration.name.text
        self.methods = methods
        self.properties = properties
        self.events = events
        self.protocols = protocols
    }

    /// A struct's stored fields, as its memberwise initializer takes them: `RaiseApproved(amount: Int)`.
    static func written(_ structure: StructDeclSyntax) -> String {
        let fields = structure.memberBlock.members.compactMap { $0.decl.as(VariableDeclSyntax.self) }.flatMap {
            variable in
            variable.bindings.compactMap { binding -> String? in
                guard binding.accessorBlock == nil, let type = binding.typeAnnotation?.type else { return nil }
                return "\(binding.pattern.trimmedDescription): \(type.trimmedDescription)"
            }
        }
        return "\(structure.name.text)(\(fields.joined(separator: ", ")))"
    }

    /// An enum's cases, each with its values: `Raise: .approved(amount: Int) | .denied`.
    static func written(_ enumeration: EnumDeclSyntax) -> String {
        let cases = enumeration.memberBlock.members.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }.flatMap {
            $0.elements.map { ".\($0.name.text)\($0.parameterClause?.trimmedDescription ?? "")" }
        }
        return "\(enumeration.name.text): \(cases.joined(separator: " | "))"
    }
}
