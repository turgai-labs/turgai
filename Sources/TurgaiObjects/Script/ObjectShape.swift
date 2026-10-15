import DiscoverableActors
import SwiftParser
import SwiftSyntax

/// What an object's data and messages are made of: plain values, which can be saved and sent,
/// and other objects.
public indirect enum ValueKind: Codable, Sendable, Equatable {
    case int, double, string, bool
    case list(ValueKind)
    case map(ValueKind)
    /// Another object: a reference, untyped, as an Erlang pid. Any type that names neither data
    /// nor a type the object declares is one, such as `owner: TripPlanner`: the name says what
    /// it's meant to be, and the object it is says what it takes.
    case object
    /// A type the object declares, or `Any`: what a value of it is gets checked when it's made.
    case other(String)

    /// The kind of a type as written, given the types the object declares.
    init(_ type: TypeSyntax, declared: Set<String>) {
        if let optional = type.as(OptionalTypeSyntax.self) {
            self.init(optional.wrappedType, declared: declared)
        } else if let unwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            self.init(unwrapped.wrappedType, declared: declared)
        } else if let array = type.as(ArrayTypeSyntax.self) {
            self = .list(ValueKind(array.element, declared: declared))
        } else if let dictionary = type.as(DictionaryTypeSyntax.self) {
            self = .map(ValueKind(dictionary.value, declared: declared))
        } else if let some = type.as(SomeOrAnyTypeSyntax.self) {
            self.init(some.constraint, declared: declared)
        } else {
            switch type.trimmedDescription {
            case "Int": self = .int
            case "Double", "Float": self = .double
            case "String": self = .string
            case "Bool": self = .bool
            case "Object": self = .object
            case let name where declared.contains(name) || name == "Any" || name == "State": self = .other(name)
            default: self = .object
            }
        }
    }

    public var written: String {
        switch self {
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .bool: "Bool"
        case .list(let element): "[\(element.written)]"
        case .map(let value): "[String: \(value.written)]"
        case .object: "Object"
        case .other(let type): type
        }
    }

    /// A value of this kind, as a JSON schema, as an action's input or output is described.
    public var schema: JSONValue {
        switch self {
        case .int: ["type": "integer"]
        case .double: ["type": "number"]
        case .string: ["type": "string"]
        case .bool: ["type": "boolean"]
        case .list(let element): ["type": "array", "items": element.schema]
        case .map(let value): ["type": "object", "additionalProperties": value.schema]
        case .object: ["x-actor-reference": true]
        case .other: [:]
        }
    }
}

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
        /// Its type as written, when it's written: otherwise its starting value's.
        public let kind: ValueKind?
        /// Its type as the code writes it, when it does.
        public let type: String?
    }

    public struct Parameter: Sendable, Equatable {
        /// What it's called with: `nil` for `_`.
        public let label: String?
        public let name: String
        public let kind: ValueKind
        /// Its type as the code writes it: `Ann` for an object, where its kind says only object.
        public let type: String

        /// As Swift declares it: `from ann: Ann`, `amount: Int`, `_ text: String`.
        public var declared: String {
            let called = label == name ? name : "\(label ?? "_") \(name)"
            return "\(called): \(type)"
        }
    }

    public struct Message: Sendable, Equatable {
        public let name: String
        public let parameters: [Parameter]
        public let reply: ValueKind?
        /// Its reply's type as the code writes it.
        public var replyType: String? = nil
        /// What its doc comment says it does.
        public var summary: String? = nil
        /// For each object it's given, what it calls on that object, as Swift names it:
        /// `askRaise(amount:from:)`.
        public var calls: [String: [String]] = [:]
        /// What its declaration says it may do besides return: wait, and throw.
        public var effects: [ObjectAction.Effect] = []

        /// As Swift declares it: `askForRaise(from ann: Ann, amount: Int) async throws -> Bool`.
        public var written: String {
            "\(name)(\(parameters.map(\.declared).joined(separator: ", ")))" + effects.map { " \($0.rawValue)" }.joined()
                + (replyType.map { " -> \($0)" } ?? "")
        }

        /// Its reply, as a JSON schema, with its type as the code writes it.
        public var output: JSONValue? {
            guard let reply, case .object(var schema) = reply.schema else { return reply?.schema }
            if let replyType { schema[Self.swiftTypeKey] = .string(replyType) }
            return .object(schema)
        }

        /// Where a schema keeps the Swift type of what it describes, and a parameter its label.
        public static let swiftTypeKey = "x-swift-type"
        public static let labelKey = "x-label"

        /// What it takes, as a JSON schema: `nil` when it takes nothing.
        public var input: JSONValue? {
            parameters.isEmpty
                ? nil
                : [
                    "type": "object",
                    "properties": .object(Dictionary(uniqueKeysWithValues: parameters.map { parameter in
                        var schema = parameter.kind.schema
                        if case .object(var members) = schema {
                            members[Self.swiftTypeKey] = .string(parameter.type)
                            members[Self.labelKey] = .string(parameter.label ?? "_")
                            schema = .object(members)
                        }
                        // An object it's given is any Object, known by what it's called with here.
                        if parameter.kind == .object, let called = calls[parameter.name], !called.isEmpty, case .object(var members) = schema {
                            members["description"] = .string("that takes " + called.joined(separator: ", "))
                            schema = .object(members)
                        }
                        return (parameter.name, schema)
                    })),
                    "required": .array(parameters.map { .string($0.name) }),
                ]
        }
    }

    public let type: String
    public let fields: [Field]
    public let messages: [Message]
    /// What it announces: its `@Event` methods, which nobody else can call.
    public let events: [Message]
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
                let assigns = node.operator.is(AssignmentExprSyntax.self)
                    || (node.operator.as(BinaryOperatorExprSyntax.self).map { $0.operator.text.hasSuffix("=") && !["==", "!=", "<=", ">="].contains($0.operator.text) } ?? false)
                if assigns, let name = Self.property(node.leftOperand), held.contains(name), !changes.contains(name) { changes.append(name) }
                return .visitChildren
            }
            override func visit(_ call: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base.flatMap(Self.property),
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
                if let member = expression.as(MemberAccessExprSyntax.self), member.base?.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.self) {
                    return member.declName.baseName.text
                }
                return nil
            }
        }
        guard let body = function.body else { return nil }
        let effects = Effects(held: held)
        effects.walk(body)
        let parts = (effects.changes.isEmpty ? [] : ["changes " + effects.changes.joined(separator: ", ")])
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
                    let written = member.declName.baseName.text + "(" + call.arguments.map { ($0.label?.text ?? "_") + ":" }.joined() + ")"
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
        try self.init(code: script.code, type: script.type, values: script.uses.interface.valueTypes)
    }

    /// The shape of the actor `type` in `code`, where `values` are types declared elsewhere that
    /// it uses; a class reads the same.
    public init(code: String, type: String, values: Set<String> = []) throws(CodeProblem) {
        let file = Parser.parse(source: code)
        let lines = SourceLocationConverter(fileName: "", tree: file)
        func line(_ node: some SyntaxProtocol) -> Int { lines.location(for: node.positionAfterSkippingLeadingTrivia).line }

        let declared: [(name: String, members: MemberBlockSyntax)] = file.statements.compactMap { statement in
            if let actor = statement.item.as(ActorDeclSyntax.self) { return (actor.name.text, actor.memberBlock) }
            if let type = statement.item.as(ClassDeclSyntax.self) { return (type.name.text, type.memberBlock) }
            return nil
        }
        guard let actor = declared.first(where: { $0.name == type }) else {
            throw CodeProblem(declared.isEmpty ? "There's no `actor \(type)`." : "The actor is named `\(declared[0].name)`, not `\(type)`.")
        }
        // The types it declares inside are its own, and those it uses are other objects' values:
        // neither is another object.
        let types = values.union(actor.members.members.compactMap { member -> String? in
            member.decl.as(EnumDeclSyntax.self)?.name.text ?? member.decl.as(StructDeclSyntax.self)?.name.text
        })
        // The data it holds, by name, to tell what each method changes.
        let held = Set(actor.members.members.flatMap { member in
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
                    fields.append(
                        Field(
                            name: name, constant: constant, kind: binding.typeAnnotation.map { ValueKind($0.type, declared: types) },
                            type: binding.typeAnnotation?.type.trimmedDescription))
                    if Self.carries(variable.attributes, RuntimeMacros.subscribed) { subscriptions.append(name) }
                }
            } else if let function = member.decl.as(FunctionDeclSyntax.self), !function.name.text.hasPrefix("_"),
                !function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate) })
            {
                let parameters = function.signature.parameterClause.parameters.map { parameter in
                    Parameter(
                        label: parameter.firstName.tokenKind == .wildcard ? nil : parameter.firstName.text,
                        name: (parameter.secondName ?? parameter.firstName).text,
                        kind: ValueKind(parameter.type, declared: types),
                        type: parameter.type.trimmedDescription)
                }
                // Any type: the reply itself is checked to be data when it's given.
                let reply = function.signature.returnClause.map { ValueKind($0.type, declared: types) }
                var message = Message(name: function.name.text, parameters: parameters, reply: reply)
                message.replyType = function.signature.returnClause?.type.trimmedDescription
                let specifiers = function.signature.effectSpecifiers
                message.effects = [specifiers?.asyncSpecifier != nil ? .async : nil, specifiers?.throwsClause != nil ? .throws : nil].compactMap { $0 }
                // What it says it does, or else what its code shows it does.
                // An event is announced by calling it, from its own code: it isn't a message.
                if Self.carries(function.attributes, RuntimeMacros.event) {
                    message.summary = Self.summary(of: function)
                    events.append(message)
                    continue
                }
                message.summary = Self.summary(of: function) ?? Self.effects(of: function, holding: held)
                for parameter in parameters where parameter.kind == .object {
                    message.calls[parameter.name] = Self.calls(on: parameter.name, in: function)
                }
                messages.append(message)
            }
        }
        // The runtime makes the object, and another object's code makes one with `Type()`: nothing
        // passes an `init` arguments.
        if let initializer = actor.members.members.compactMap({ $0.decl.as(InitializerDeclSyntax.self) })
            .first(where: { !$0.signature.parameterClause.parameters.isEmpty })
        {
            throw CodeProblem(
                line: line(initializer), span: "init\(initializer.signature.trimmedDescription)",
                "needs no parameters: the runtime makes the object", phrasing: .statement)
        }
        self.type = type
        self.fields = fields
        self.messages = messages
        self.events = events
        self.subscriptions = subscriptions
        self.checks = checks
    }
}
