import DiscoverableActors
import Doppel
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

/// An object's code as it's kept: its Swift, as it was written, and the actor in it that's the
/// object. Everything else about it is read from the code: its shape, the states it's in, and its
/// YAML, which ``ObjectSource`` shows next to it.
public struct Script: Codable, Sendable, Equatable {
    /// The actor that's the object.
    public let type: String
    /// Its Swift, as written.
    public let code: String
    /// What it was written against: the other objects and their values, as the module its code
    /// imports, and the names objects are reached by.
    public let uses: Uses

    /// `code`, whose object is the actor `type`. It's refused, with where, when it
    /// isn't Swift, or declares no such actor, as the Swift compiler refuses a file.
    public init(code: String, type: String, uses: Uses = .nothing) throws(CodeProblem) {
        let file = Parser.parse(source: code)
        let lines = SourceLocationConverter(fileName: "", tree: file)
        func line(_ node: some SyntaxProtocol) -> Int {
            lines.location(for: node.positionAfterSkippingLeadingTrivia).line
        }
        // A declaration modifier written as an attribute, `@actor`, is what's wrong, as Swift says:
        // what follows it isn't read as a declaration.
        for statement in file.statements {
            let tokens = Array(statement.tokens(viewMode: .sourceAccurate).prefix(2))
            if tokens.count == 2, tokens[0].tokenKind == .atSign,
                SwiftCheck.declarationModifiers.contains(tokens[1].text)
            {
                throw CodeProblem(
                    line: line(statement), span: "@\(tokens[1].text)",
                    "'\(tokens[1].text)' is a declaration modifier, not an attribute: it's written without '@'")
            }
        }
        guard file.statements.contains(where: { $0.item.is(DeclSyntax.self) }) else {
            throw CodeProblem("The answer isn't Swift code.")
        }
        if let error = ParseDiagnosticsGenerator.diagnostics(for: file).first(where: {
            $0.diagMessage.severity == .error
        }) {
            throw CodeProblem(line: lines.location(for: error.position).line, error.message)
        }
        var actor: ActorDeclSyntax?
        // What's outside the actor never runs: the runtime only declares the file, and runs the
        // object's methods when it's asked.
        func outside(_ statement: some SyntaxProtocol) -> CodeProblem {
            let written = statement.trimmedDescription.split(separator: "\n").first.map(String.init) ?? ""
            return CodeProblem(
                line: line(statement), span: written,
                "is outside the actor: code there never runs, so it goes inside `actor \(type)`", phrasing: .statement)
        }
        for statement in file.statements {
            // Code that runs when it's loaded, such as trying the object out.
            guard let declaration = statement.item.as(DeclSyntax.self) else { throw outside(statement) }
            // Values and functions of their own, outside the actor: what the object keeps and
            // does is the actor's.
            if declaration.is(VariableDeclSyntax.self) || declaration.is(FunctionDeclSyntax.self) {
                throw outside(declaration)
            }
            let named: (kind: String, name: String)? =
                if let decl = declaration.as(ActorDeclSyntax.self) {
                    ("actor", decl.name.text)
                } else if let decl = declaration.as(ClassDeclSyntax.self) {
                    ("class", decl.name.text)
                } else if let decl = declaration.as(StructDeclSyntax.self) {
                    ("struct", decl.name.text)
                } else if let decl = declaration.as(EnumDeclSyntax.self) { ("enum", decl.name.text) } else { nil }
            guard let named, named.name == type else { continue }
            guard actor == nil else { throw CodeProblem(line: line(declaration), "invalid redeclaration of '\(type)'") }
            guard let decl = declaration.as(ActorDeclSyntax.self) else {
                throw CodeProblem(
                    line: line(declaration), "`\(type)` is a \(named.kind): the object is `actor \(type)`.")
            }
            actor = decl
        }
        guard actor != nil else { throw CodeProblem("There's no `actor \(type)`.") }
        self.type = type
        self.code = code
        self.uses = uses
    }

    /// The types whose objects last, as virtual actors: those it was written against that do, and
    /// the actors its code declares, each made as one.
    public var lasting: Set<String> {
        uses.lasting.union(
            Parser.parse(source: code).statements.compactMap { $0.item.as(ActorDeclSyntax.self)?.name.text })
    }

    /// Whether, in the state named `state`, it takes `message`, as its YAML view reads its states:
    /// code it can't read as states takes every message.
    public func takes(_ message: String, in state: String?) -> Bool {
        (try? ObjectSource(self))?.takes(message, in: state) ?? true
    }

    /// The types its code makes with `Type()` that it doesn't declare: other objects' types, each
    /// reached by its id, the type's name.
    public var madeTypes: [String] {
        final class Made: SyntaxVisitor {
            var declared: Set<String> = []
            var made: [String] = []

            override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
                declared.insert(node.name.text)
                return .visitChildren
            }
            override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
                declared.insert(node.name.text)
                return .visitChildren
            }
            override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
                declared.insert(node.name.text)
                return .visitChildren
            }
            override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
                declared.insert(node.name.text)
                return .visitChildren
            }

            override func visit(_ call: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
                    name.first?.isUppercase == true
                {
                    made.append(name)
                }
                return .visitChildren
            }

            init() { super.init(viewMode: .sourceAccurate) }
        }
        // As it runs: a `@Subscribed` property's object is made by its type there.
        let made = Made()
        made.walk(Parser.parse(source: ObjectModule.expanded(code, type: type)))
        var seen: Set<String> = []
        return made.made.filter { !made.declared.contains($0) && seen.insert($0).inserted }
    }

    /// What's certain to go wrong with what it reads of itself: `self.x` where it declares no `x`.
    public var selfProblems: [CodeProblem] {
        final class Members: SyntaxVisitor {
            var declared: Set<String> = ["state"]
            var used: [String] = []

            override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
                for binding in node.bindings { declared.insert(binding.pattern.trimmedDescription) }
                return .visitChildren
            }

            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
                declared.insert(node.name.text)
                return .visitChildren
            }

            override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                if node.base?.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.self) {
                    used.append(node.declName.baseName.text)
                }
                return .visitChildren
            }

            init() { super.init(viewMode: .sourceAccurate) }
        }
        let members = Members()
        members.walk(Parser.parse(source: code))
        let held = ((try? ObjectShape(self))?.fields ?? []).map(\.name).joined(separator: ", ")
        var seen: Set<String> = []
        return members.used.filter { !members.declared.contains($0) && seen.insert($0).inserted }.map { name in
            CodeProblem("`self.\(name)` isn't declared: it holds \(held.isEmpty ? "nothing" : held).")
        }
    }
}

extension Script {
    /// The key of a property's schema saying it's `private`: no other object's code reads it.
    public static let privateKey = "x-private"

    /// Its object's spec, read from its code: what it takes, what it announces, and what it
    /// holds, `holding` these values, when it has any. Its type is described the same with an
    /// object or without one.
    public func spec(description: String?, holding values: [String: JSONValue] = [:]) throws(CodeProblem)
        -> ObjectDescription
    {
        try CheckedScript(self).spec(description: description, holding: values)
    }

    /// The declarations the checker resolves in its module, or `nil` when they don't resolve.
    func declarations() -> Declarations? {
        SwiftCheck.declarations(of: type, in: ObjectModule.objectFile, of: ScriptInstance.files(self)).declarations
    }
}

/// A script as the checker reads it: its shape, and the declarations its module resolves. Reading
/// is what describing an object costs, so whoever lists or runs a script keeps it read, and reads
/// it again only when the code is another.
public struct CheckedScript: Sendable {
    public let script: Script
    public let shape: ObjectShape
    let declarations: Declarations?

    public init(_ script: Script) throws(CodeProblem) {
        var shape = try ObjectShape(code: script.code, type: script.type)
        let declarations = script.declarations()
        shape.resolve(script.type, by: declarations)
        self.script = script
        self.shape = shape
        self.declarations = declarations
    }

    /// Its object's spec, as ``Script/spec(description:holding:)`` says.
    public func spec(description: String?, holding values: [String: JSONValue] = [:]) -> ObjectDescription {
        let type = script.type
        var properties: [String: JSONValue] = [:]
        for field in shape.fields {
            // Its Swift type, when the checker resolved it, or else what it holds now.
            var schema: [String: JSONValue]
            if field.resolved != .unresolved, let declarations, let written = SwiftTypeSchema.written(field.resolved),
                case .object(let typed) = SwiftTypeSchema.schema(of: field.resolved, in: declarations)
            {
                schema = typed
                schema[ObjectShape.Message.swiftTypeKey] = .string(written)
            } else {
                schema = DynamicObject.schema(of: values[field.name] ?? .null)
            }
            schema["readOnly"] = true
            // A `private` one is its own: shown to whoever uses it, never to other objects' code.
            if !field.published { schema[Script.privateKey] = true }
            properties[field.name] = .object(schema)
        }
        var actions: [String: ObjectAction] = [:]
        for message in shape.messages {
            actions[shape.actionKey(of: message)] = ObjectAction(
                description: message.summary, input: message.input, output: message.output, effects: message.effects)
        }
        // Each event as its type is declared: its value is what subscribers are sent.
        var events: [String: ObjectEvent] = [:]
        for event in shape.events {
            let data =
                declarations.map { SwiftTypeSchema.schema(of: .named("\(type).\(event.name)", arguments: []), in: $0) }
                ?? ["type": "object", "properties": [:]]
            events[event.name] = ObjectEvent(description: event.summary, data: data)
        }
        // The protocols it declares within it, each requirement described as an action is.
        var protocols: [String: ObjectProtocol] = [:]
        for (name, declaration) in declarations?.types ?? [:] where name.hasPrefix("\(type).") {
            guard case .protocol(let requirements, let documentation) = declaration, let declarations else { continue }
            var described: [String: ObjectAction] = [:]
            for requirement in requirements {
                let parameters = requirement.parameters.map { parameter in
                    ObjectShape.Parameter(
                        label: parameter.label, name: parameter.name,
                        type: SwiftTypeSchema.written(parameter.type) ?? "Object")
                }
                var message = ObjectShape.Message(name: requirement.name, parameters: parameters)
                if requirement.result != .void { message.replyType = SwiftTypeSchema.written(requirement.result) }
                message = ObjectShape.typed(message, by: [requirement], in: declarations)
                described[requirement.name] = ObjectAction(
                    description: requirement.documentation, input: message.input, output: message.output,
                    effects: [requirement.effects.async ? .async : nil, requirement.effects.throwing ? .throws : nil]
                        .compactMap { $0 })
            }
            protocols[name] = ObjectProtocol(description: documentation, requirements: described)
        }
        return ObjectDescription(
            type: type, description: description, properties: properties, actions: actions, events: events,
            protocols: protocols)
    }
}
