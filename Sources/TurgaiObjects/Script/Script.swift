import DiscoverableActors
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

/// An object's kind as it's kept: its Swift, as it was written, and the actor in it that's the
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

    /// `code` as the kind whose object is the actor `type`. It's refused, with where, when it
    /// isn't Swift, or declares no such actor, as the Swift compiler refuses a file.
    public init(code: String, type: String, uses: Uses = .nothing) throws(CodeProblem) {
        let file = Parser.parse(source: code)
        guard file.statements.contains(where: { $0.item.is(DeclSyntax.self) }) else {
            throw CodeProblem("The answer isn't Swift code.")
        }
        let lines = SourceLocationConverter(fileName: "", tree: file)
        func line(_ node: some SyntaxProtocol) -> Int { lines.location(for: node.positionAfterSkippingLeadingTrivia).line }
        if let error = ParseDiagnosticsGenerator.diagnostics(for: file).first(where: { $0.diagMessage.severity == .error }) {
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
            if declaration.is(VariableDeclSyntax.self) || declaration.is(FunctionDeclSyntax.self) { throw outside(declaration) }
            let named: (kind: String, name: String)? =
                if let decl = declaration.as(ActorDeclSyntax.self) { ("actor", decl.name.text) }
                else if let decl = declaration.as(ClassDeclSyntax.self) { ("class", decl.name.text) }
                else if let decl = declaration.as(StructDeclSyntax.self) { ("struct", decl.name.text) }
                else if let decl = declaration.as(EnumDeclSyntax.self) { ("enum", decl.name.text) }
                else { nil }
            guard let named, named.name == type else { continue }
            guard actor == nil else { throw CodeProblem(line: line(declaration), "invalid redeclaration of '\(type)'") }
            guard let decl = declaration.as(ActorDeclSyntax.self) else {
                throw CodeProblem(line: line(declaration), "`\(type)` is a \(named.kind): the object is `actor \(type)`.")
            }
            actor = decl
        }
        guard actor != nil else { throw CodeProblem("There's no `actor \(type)`.") }
        self.type = type
        self.code = code
        self.uses = uses
    }

    /// Its code with the runtime's macros expanded: what runs, with the module it imports.
    public var expanded: String { RuntimeMacros.expanding(code) }

    /// Whether, in the state named `state`, it takes `message`, as its YAML view reads its states:
    /// code it can't read as states takes every message.
    public func takes(_ message: String, in state: String?) -> Bool {
        (try? ObjectSource(swift: code, type: type))?.takes(message, in: state) ?? true
    }

    /// The objects its code talks to by name: what it calls a method on that it doesn't declare,
    /// such as `bookings` in `bookings.confirm(trip: trip)`. Each is found by that name when it's
    /// called.
    public var namedObjects: [String] {
        final class Names: SyntaxVisitor {
            var declared: Set<String> = ["self", "super"]
            var called: [String] = []

            override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
                declared.insert(node.identifier.text)
                return .visitChildren
            }

            override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
                declared.insert((node.secondName ?? node.firstName).text)
                return .visitChildren
            }

            override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
                declared.insert(node.name.text)
                return .visitChildren
            }

            override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
                declared.insert((node.secondName ?? node.firstName).text)
                return .visitChildren
            }

            override func visit(_ call: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                    let base = member.base?.as(DeclReferenceExprSyntax.self),
                    let first = base.baseName.text.first, first.isLowercase
                {
                    called.append(base.baseName.text)
                }
                return .visitChildren
            }

            init() { super.init(viewMode: .sourceAccurate) }
        }
        let names = Names()
        names.walk(Parser.parse(source: code))
        var seen: Set<String> = []
        return names.called.filter { !names.declared.contains($0) && seen.insert($0).inserted }
    }

    /// The types its code makes with `Type()` that it doesn't declare: other objects' types, each
    /// reached by its id, the type's name.
    public var madeTypes: [String] {
        final class Made: SyntaxVisitor {
            var declared: Set<String> = []
            var made: [String] = []

            override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { declared.insert(node.name.text); return .visitChildren }
            override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { declared.insert(node.name.text); return .visitChildren }
            override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { declared.insert(node.name.text); return .visitChildren }
            override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { declared.insert(node.name.text); return .visitChildren }

            override func visit(_ call: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text, name.first?.isUppercase == true {
                    made.append(name)
                }
                return .visitChildren
            }

            init() { super.init(viewMode: .sourceAccurate) }
        }
        // As it runs: a `@Subscribed` property's object is made by its type there.
        let made = Made()
        made.walk(Parser.parse(source: expanded))
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
    /// Its object's spec, read from its code: what it takes, what it announces, and what it
    /// holds, `holding` these values, when it has any. A kind is described the same with an
    /// object or without one.
    public func spec(title: String, description: String?, holding values: [String: JSONValue] = [:]) throws(CodeProblem) -> ObjectDescription {
        let shape = try ObjectShape(self)
        var properties: [String: JSONValue] = [:]
        for field in shape.fields {
            var schema = DynamicObject.schema(of: values[field.name] ?? .null)
            schema["readOnly"] = true
            properties[field.name] = .object(schema)
        }
        var actions: [String: ObjectAction] = [:]
        for message in shape.messages {
            actions[message.name] = ObjectAction(
                description: message.summary, input: message.input, output: message.output, effects: message.effects)
        }
        var events: [String: ObjectEvent] = [:]
        for event in shape.events {
            events[event.name] = ObjectEvent(description: event.summary, data: event.input ?? ["type": "object", "properties": [:]])
        }
        return ObjectDescription(title: title, description: description, properties: properties, actions: actions, events: events)
    }
}
