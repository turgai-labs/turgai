import DiscoverableActors
import SwiftParser
import Doppel
import SwiftSyntax

/// What's wrong with an object's code, in a line, at a line of it when that's known.
public struct CodeProblem: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let line: Int?
    /// The code it's about, within its line, when it's known.
    public let span: String?
    public let message: String
    public let phrasing: Phrasing

    /// How the message reads with its code: as the reason after it, or as a statement about it,
    /// `` `ann.approveRaise(amount)` needs await ``.
    public enum Phrasing: Codable, Sendable, Equatable { case reason, statement }

    public init(line: Int? = nil, span: String? = nil, _ message: String, phrasing: Phrasing = .reason) {
        self.line = line
        self.span = span
        self.message = message
        self.phrasing = phrasing
    }

    public var description: String { line.map { "line \($0): \(message)" } ?? message }

    /// What's wrong, at the code of `code` it's about, quoted: the span within its line, as
    /// `` `Ann.approveRaise` in `if Ann.approveRaise(amount) {`: … ``, or the line alone. Whoever
    /// reads it needn't have the code.
    public func written(in code: String) -> String {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        guard let line, lines.indices.contains(line - 1) else { return description }
        let quoted = lines[line - 1].trimmingCharacters(in: .whitespaces)
        guard !quoted.isEmpty else { return description }
        // A statement is about its code, whole: `func askForRaise(amount: Int)` needs async.
        if phrasing == .statement, let span, !span.contains("\n") { return "`\(span)` \(message)" }
        // A span is shown when it's part of its line: a whole declaration isn't.
        if let span, span != quoted, !span.contains("\n"), quoted.contains(span) {
            return "`\(span)` in `\(quoted)`: \(message)"
        }
        return "`\(quoted)`: \(message)"
    }
}

/// An object's actor as its code declares it: the data it holds and the messages it takes, each
/// typed. Its code runs only to handle a message, with the data going in and coming back out, the
/// way an Erlang process's state goes through its `receive` loop.
public struct ObjectShape: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public let name: String
        /// Written with `let`: it keeps its starting value.
        public let constant: Bool
        /// Its type as the code writes it, when it does.
        public let type: String?
        /// Its type as the checker resolved it: `.unresolved` for code that doesn't check.
        public var resolved: SwiftType = .unresolved
        /// Not `private`: other objects read it, as another actor's property is read in Swift.
        public var published = true
    }

    public struct Parameter: Sendable, Equatable {
        /// What it's called with: `nil` for `_`.
        public let label: String?
        public let name: String
        /// Its type as the code writes it.
        public let type: String
        /// Its type as the checker resolved it: `.unresolved` for code that doesn't check.
        public var resolved: SwiftType = .unresolved
        /// The schema a value of it is described with, from its resolved type.
        public var schema: JSONValue = [:]
        /// It may be left out: it's optional, or has a default.
        public var optional = false
        /// Its type as code elsewhere names it, `RefundDesk.Refund`: `nil` for any object, which
        /// is written as it's declared.
        public var qualified: String? = nil
        /// The object it takes, when it takes one: `nil` for a value.
        public var object: Takes? = nil

        /// As Swift declares it: `from ann: Ann`, `amount: Int`, `_ text: String`.
        public var declared: String {
            let called = label == name ? name : "\(label ?? "_") \(name)"
            return "\(called): \(type)"
        }
    }

    /// The object a parameter takes.
    public enum Takes: Sendable, Equatable {
        /// Any object: `Object`.
        case anyObject
        /// An object of an actor type.
        case of(ObjectTypeName)
        /// An object conforming to a protocol: `any Shop.RefundManager`.
        case conforming(to: ObjectProtocolName)
    }

    public struct Message: Sendable, Equatable {
        public let name: String
        public var parameters: [Parameter]
        /// Its reply's type as the code writes it: `nil` when it returns nothing.
        public var replyType: String? = nil
        /// Its reply's schema, from its resolved type: `nil` when it returns nothing.
        public var replySchema: JSONValue? = nil
        /// What its doc comment says it does.
        public var summary: String? = nil
        /// For each object it's given, what it calls on that object, as Swift names it:
        /// `askRaise(amount:from:)`.
        public var calls: [String: [String]] = [:]
        /// What its declaration says it may do besides return: wait, and throw.
        public var effects: [ObjectAction.Effect] = []
        /// As Swift declares it: `askForRaise(from ann: Ann, amount: Int) async throws -> Bool`.
        public var written: String {
            "\(name)(\(parameters.map(\.declared).joined(separator: ", ")))"
                + effects.map { " \($0.rawValue)" }.joined()
                + (replyType.map { " -> \($0)" } ?? "")
        }

        /// Its reply, as a JSON schema: `nil` when it returns nothing.
        public var output: JSONValue? { replySchema }

        /// Where a schema keeps the Swift type of what it describes, and a parameter its label.
        public static let swiftTypeKey = "x-swift-type"
        public static let labelKey = "x-label"

        /// What it takes, as a JSON schema: `nil` when it takes nothing.
        public var input: JSONValue? {
            parameters.isEmpty
                ? nil
                : [
                    "type": "object",
                    "properties": .object(
                        Dictionary(
                            uniqueKeysWithValues: parameters.map { parameter in
                                var schema = parameter.schema
                                if case .object(var members) = schema {
                                    members[Self.swiftTypeKey] = .string(parameter.qualified ?? parameter.type)
                                    members[Self.labelKey] = .string(parameter.label ?? "_")
                                    schema = .object(members)
                                }
                                // An object it's given is any Object, known by what it's called with here.
                                if parameter.object == .anyObject, let called = calls[parameter.name], !called.isEmpty,
                                    case .object(var members) = schema
                                {
                                    members["description"] = .string("that takes " + called.joined(separator: ", "))
                                    schema = .object(members)
                                }
                                return (parameter.name, schema)
                            })),
                    "required": .array(parameters.filter { !$0.optional }.map { .string($0.name) }),
                ]
        }
    }

    public let type: String
    public private(set) var fields: [Field]
    public private(set) var messages: [Message]
    /// What it announces: its `@Event` methods, which nobody else can call.
    public private(set) var events: [Message]
    /// The fields whose object it follows the events of: its `@Subscribed` properties.
    public let subscriptions: [String]
    /// Whether it declares `_check()`, which says which of its checks its data breaks, if any.
    public let checks: Bool

    /// Whether a declaration carries the runtime's macro `name`.
    static func carries(_ attributes: AttributeListSyntax, _ name: String) -> Bool {
        attributes.contains { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == name }
    }

    /// A declaration's `///` comment, as one line.
    static func summary(of function: FunctionDeclSyntax) -> String? {
        let lines = function.leadingTrivia.compactMap { piece -> String? in
            if case .docLineComment(let text) = piece { return text.dropFirst(3).trimmingCharacters(in: .whitespaces) }
            return nil
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// What a method's code shows it does, in a line: the data it changes, and the other objects'
    /// methods it calls, `changes pay; calls ann.approveRaise`. `nil` when it does neither.
    static func effects(of function: FunctionDeclSyntax, holding held: Set<String>) -> String? {
        final class Effects: SyntaxVisitor {
            let held: Set<String>
            var changes: [String] = []
            var calls: [String] = []
            init(held: Set<String>) {
                self.held = held
                super.init(viewMode: .sourceAccurate)
            }
            override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
                let assigns =
                    node.operator.is(AssignmentExprSyntax.self)
                    || (node.operator.as(BinaryOperatorExprSyntax.self).map {
                        $0.operator.text.hasSuffix("=") && !["==", "!=", "<=", ">="].contains($0.operator.text)
                    } ?? false)
                if assigns, let name = Self.property(node.leftOperand), held.contains(name), !changes.contains(name) {
                    changes.append(name)
                }
                return .visitChildren
            }
            override func visit(_ call: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                    let base = member.base.flatMap(Self.property),
                    base != "self"
                {
                    let written = "\(base).\(member.declName.baseName.text)"
                    // A data's own method, such as `items.append`, changes it; another object's is a call.
                    if held.contains(base) {
                        if !changes.contains(base) { changes.append(base) }
                    } else if !calls.contains(written) {
                        calls.append(written)
                    }
                }
                return .visitChildren
            }
            /// The property an expression names: `x` or `self.x`.
            static func property(_ expression: ExprSyntax) -> String? {
                if let reference = expression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
                if let member = expression.as(MemberAccessExprSyntax.self),
                    member.base?.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.self)
                {
                    return member.declName.baseName.text
                }
                return nil
            }
        }
        guard let body = function.body else { return nil }
        let effects = Effects(held: held)
        effects.walk(body)
        let parts =
            (effects.changes.isEmpty ? [] : ["changes " + effects.changes.joined(separator: ", ")])
            + (effects.calls.isEmpty ? [] : ["calls " + effects.calls.joined(separator: ", ")])
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// What a method calls on `name`, by Swift's names for them: `askRaise(amount:from:)`.
    static func calls(on name: String, in function: FunctionDeclSyntax) -> [String] {
        final class Calls: SyntaxVisitor {
            let name: String
            var found: [String] = []
            init(name: String) {
                self.name = name
                super.init(viewMode: .sourceAccurate)
            }
            override func visit(_ call: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                    member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == name
                {
                    let written =
                        member.declName.baseName.text + "("
                        + call.arguments.map { ($0.label?.text ?? "_") + ":" }.joined() + ")"
                    if !found.contains(written) { found.append(written) }
                }
                return .visitChildren
            }
        }
        let calls = Calls(name: name)
        calls.walk(function)
        return calls.found
    }

    /// The shape of `script`'s actor: with the types other objects' values are, which it uses.
    public init(_ script: Script) throws(CodeProblem) {
        try self.init(code: script.code, type: script.type)
        // Its values' types as the checker resolved them, for code that checks.
        guard
            let declarations = SwiftCheck.declarations(
                of: script.type, in: ObjectModule.objectFile, of: ScriptInstance.files(script)
            ).declarations,
            case .actor(let held, let methods, _, _)? = declarations[script.type]
        else { return }
        fields = fields.map { field in
            var field = field
            field.resolved = held.first { $0.name == field.name }?.type ?? .unresolved
            return field
        }
        messages = messages.map { Self.typed($0, by: methods, in: declarations) }
        events = events.map { Self.typed($0, by: methods, in: declarations) }
    }

    /// `message` with its parameters' and reply's types as the checker resolved them.
    static func typed(_ message: Message, by methods: [Declarations.Method], in declarations: Declarations) -> Message {
        guard
            let method = methods.first(where: {
                $0.name == message.name && $0.parameters.map(\.label) == message.parameters.map(\.label)
            })
        else { return message }
        var message = message
        for (index, resolved) in method.parameters.enumerated() where index < message.parameters.count {
            var parameter = message.parameters[index]
            parameter.resolved = resolved.type
            parameter.schema = SwiftTypeSchema.schema(of: resolved.type, in: declarations)
            parameter.optional = SwiftTypeSchema.isOptional(resolved.type) || resolved.hasDefault
            parameter.qualified = SwiftTypeSchema.written(resolved.type)
            if case .named(let name, _) = resolved.type.unwrapped, case .actor? = declarations[name] {
                parameter.object = .of(ObjectTypeName(rawValue: name))
            } else if let conformed = SwiftTypeSchema.conformed(resolved.type, in: declarations) {
                parameter.object = .conforming(to: conformed)
            } else if SwiftTypeSchema.isAnyObject(resolved.type) {
                parameter.object = .anyObject
            }
            message.parameters[index] = parameter
        }
        if message.replyType != nil {
            message.replySchema = SwiftTypeSchema.schema(of: method.result, in: declarations)
        }
        return message
    }

    /// The shape of the actor `type` in `code`, as written; a class reads the same. Its types are
    /// the checker's, which ``init(_:)`` adds.
    init(code: String, type: String) throws(CodeProblem) {
        let file = Parser.parse(source: code)
        let lines = SourceLocationConverter(fileName: "", tree: file)
        func line(_ node: some SyntaxProtocol) -> Int {
            lines.location(for: node.positionAfterSkippingLeadingTrivia).line
        }

        let declared: [(name: String, members: MemberBlockSyntax)] = file.statements.compactMap { statement in
            if let actor = statement.item.as(ActorDeclSyntax.self) { return (actor.name.text, actor.memberBlock) }
            if let type = statement.item.as(ClassDeclSyntax.self) { return (type.name.text, type.memberBlock) }
            return nil
        }
        guard let actor = declared.first(where: { $0.name == type }) else {
            throw CodeProblem(
                declared.isEmpty
                    ? "There's no `actor \(type)`." : "The actor is named `\(declared[0].name)`, not `\(type)`.")
        }
        // The data it holds, by name, to tell what each method changes.
        let held = Set(
            actor.members.members.flatMap { member in
                member.decl.as(VariableDeclSyntax.self)?.bindings.map(\.pattern.trimmedDescription) ?? []
            })
        var fields: [Field] = []
        var messages: [Message] = []
        var events: [Message] = []
        var subscriptions: [String] = []
        var checks = false
        for member in actor.members.members {
            if let function = member.decl.as(FunctionDeclSyntax.self), function.name.text == "_check" { checks = true }
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                let constant = variable.bindingSpecifier.tokenKind == .keyword(.let)
                for binding in variable.bindings {
                    // A computed property is worked out from data; it isn't data.
                    if binding.accessorBlock != nil { continue }
                    // What it starts as is its default or what `init()` sets, which the check
                    // makes sure of, as Swift's definite initialization does.
                    let name = binding.pattern.trimmedDescription
                    var field = Field(
                        name: name, constant: constant, type: binding.typeAnnotation?.type.trimmedDescription)
                    field.published = !variable.modifiers.contains { modifier in
                        [.keyword(.private), .keyword(.fileprivate)].contains(modifier.name.tokenKind)
                            && modifier.detail == nil
                    }
                    fields.append(field)
                    if Self.carries(variable.attributes, RuntimeMacros.subscribed) { subscriptions.append(name) }
                }
            } else if let function = member.decl.as(FunctionDeclSyntax.self), !function.name.text.hasPrefix("_"),
                !function.modifiers.contains(where: {
                    $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)
                })
            {
                let parameters = function.signature.parameterClause.parameters.map { parameter in
                    Parameter(
                        label: parameter.firstName.tokenKind == .wildcard ? nil : parameter.firstName.text,
                        name: (parameter.secondName ?? parameter.firstName).text,
                        type: parameter.type.trimmedDescription)
                }
                var message = Message(name: function.name.text, parameters: parameters)
                message.replyType = function.signature.returnClause?.type.trimmedDescription
                // Until the checker resolves it, a reply is known by its type as written.
                message.replySchema = message.replyType.map { [Message.swiftTypeKey: .string($0)] }
                let specifiers = function.signature.effectSpecifiers
                message.effects = [
                    specifiers?.asyncSpecifier != nil ? .async : nil, specifiers?.throwsClause != nil ? .throws : nil,
                ].compactMap { $0 }
                // What it says it does, or else what its code shows it does.
                // An event is announced by calling it, from its own code: it isn't a message.
                if Self.carries(function.attributes, RuntimeMacros.event) {
                    message.summary = Self.summary(of: function)
                    events.append(message)
                    continue
                }
                message.summary = Self.summary(of: function) ?? Self.effects(of: function, holding: held)
                // What it calls on each parameter: what an object it's given is known by.
                for parameter in parameters {
                    let called = Self.calls(on: parameter.name, in: function)
                    if !called.isEmpty { message.calls[parameter.name] = called }
                }
                messages.append(message)
            }
        }
        // How its stored properties get their values, as an object's do.
        if let problem = StartingValues.problems(in: code, type: type).first { throw problem }
        self.type = type
        self.fields = fields
        self.messages = messages
        self.events = events
        self.subscriptions = subscriptions
        self.checks = checks
    }
}
