import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax
import Yams

/// An object's type as a person reads it, next to its code: what it holds and what it follows, the
/// checks that always hold, the states it can be in, how it handles each message, as rules where
/// its code reads as rules and as code where it doesn't, what it announces, the protocols it
/// declares and those it conforms to. It's read from a ``Script``'s Swift, as YAML to show. The
/// script is the type: this is a view of it.
public struct ObjectSource: Codable, Sendable, Equatable {
    /// Something it holds, as a Swift binding: `approveBelow: Double = 500`.
    public struct Datum: Codable, Sendable, Equatable {
        let name: String
        /// `let`: a setting, kept as it starts.
        let constant: Bool
        let type: String?
        let start: String
        /// `private`: its own, never read by other objects.
        var isPrivate = false

        var written: String { (isPrivate ? "private " : "") + "\(name)\(type.map { ": \($0)" } ?? "") = \(start)" }
    }

    /// How it handles one message.
    public enum Handling: Codable, Sendable, Equatable {
        /// Erlang's clauses: the first whose `when` holds runs its `do`; one with no `when` takes
        /// the rest.
        case rules([Clause])
        /// Anything that isn't rules: the method's body as written.
        case code(String)
    }

    public struct Clause: Codable, Sendable, Equatable {
        /// Swift's condition, such as `total < approveBelow` or `let index = items.firstIndex(of: item)`.
        let when: String?
        /// Swift statements, in order.
        let actions: [String]
    }

    public struct Message: Codable, Sendable, Equatable {
        /// `tripPlanned(trip: String, total: Double) -> String`
        let signature: String
        let handling: Handling

        var name: String { String(signature.prefix { $0 != "(" }) }
    }

    /// A protocol it declares: its name, and its requirements as Swift declares them.
    public struct Declared: Codable, Sendable, Equatable {
        let name: String
        let requirements: [String]
    }

    /// A state it can be in, and the messages it takes there, as SCXML's transitions of a state.
    public struct State: Codable, Sendable, Equatable {
        let name: String
        /// What it holds while in it, as an enum case's associated values: `trip: String, total: Double`.
        var values: String? = nil
        public let receive: [Message]

        /// Its associated values' labels, which a case binds by name.
        var labels: [String] {
            (values ?? "").split(separator: ",").map {
                String($0.split(separator: ":").first ?? "").trimmingCharacters(in: .whitespaces)
            }
        }

        var written: String { name + (values.map { "(\($0))" } ?? "") }
    }

    public let object: String
    public let data: [Datum]
    /// Swift conditions that hold after every message, as Pkl's constraints: a message that would
    /// break one changes nothing.
    public let checks: [String]
    /// The state it starts in, when it has states.
    public let initial: String?
    public let states: [State]
    /// Messages it takes in every state.
    let receive: [Message]
    /// The objects it follows, its `@Subscribed` properties, each as a binding.
    public var follows: [Datum] = []
    /// The events it announces, its `@Event` functions, as Swift declares each.
    public var announces: [String] = []
    /// The protocols it declares, each with its requirements as Swift declares them.
    public var protocols: [Declared] = []
    /// The protocols it conforms to, as its declaration says.
    public var conforms: [String] = []
    /// Members that aren't data or messages, such as private methods, as Swift.
    public let helpers: String?

    /// Every message it takes, in any state, in the order first written.
    public var messages: [String] {
        var names: [String] = []
        for message in receive + states.flatMap(\.receive) where !names.contains(message.name) {
            names.append(message.name)
        }
        return names
    }

    /// Whether it takes `message` in `state`.
    public func takes(_ message: String, in state: String?) -> Bool {
        if receive.contains(where: { $0.name == message }) { return true }
        guard let state else { return states.isEmpty }
        return states.first { $0.name == state }?.receive.contains { $0.name == message } ?? false
    }
}

// MARK: - Swift to config

extension ObjectSource {
    /// The type `script` defines, with the objects its module declares.
    public init(_ script: Script) throws(CodeProblem) {
        try self.init(swift: script.code, type: script.type)
    }

    /// The type an actor's code defines; a class reads the same. Code outside the actor is left
    /// out: an object is its actor. Its states are an `enum State` held in `var state`, and a
    /// method that switches on `state` handles its message state by state.
    public init(swift code: String, type: String) throws(CodeProblem) {
        let file = Parser.parse(source: code)
        // Code that isn't Swift is never kept, whatever an interpreter would make of it.
        if let error = ParseDiagnosticsGenerator.diagnostics(for: file).first(where: {
            $0.diagMessage.severity == .error
        }) {
            let line = SourceLocationConverter(fileName: "", tree: file).location(for: error.position).line
            throw CodeProblem(line: line, error.message)
        }
        let declared: [(name: String, members: MemberBlockSyntax, inheritance: InheritanceClauseSyntax?)] = file
            .statements.compactMap {
                statement in
                if let actor = statement.item.as(ActorDeclSyntax.self) {
                    return (actor.name.text, actor.memberBlock, actor.inheritanceClause)
                }
                if let type = statement.item.as(ClassDeclSyntax.self) {
                    return (type.name.text, type.memberBlock, type.inheritanceClause)
                }
                return nil
            }
        guard let actor = declared.first(where: { $0.name == type }) else {
            throw CodeProblem("There's no `actor \(type)`.")
        }
        let members = actor.members.members.map(\.decl)
        // Its states: an `enum State` of plain cases, in the actor or beside it.
        var stateNames: [String] = []
        var stateValues: [String: String] = [:]
        let enums =
            members.compactMap { $0.as(EnumDeclSyntax.self) }
            + file.statements.compactMap { $0.item.as(EnumDeclSyntax.self) }
        if let states = enums.first(where: { $0.name.text == "State" }) {
            for element in states.memberBlock.members.compactMap({ $0.decl.as(EnumCaseDeclSyntax.self) }).flatMap(
                \.elements)
            {
                stateNames.append(element.name.text)
                if let parameters = element.parameterClause?.parameters {
                    stateValues[element.name.text] = parameters.trimmedDescription
                }
            }
        }
        var data: [Datum] = []
        var checks: [String] = []
        var initial: String?
        var receive: [Message] = []
        var byState: [String: [Message]] = [:]
        var helpers: [String] = []
        var follows: [Datum] = []
        var announces: [String] = []
        var protocols: [Declared] = []
        for declaration in members {
            if let states = declaration.as(EnumDeclSyntax.self), states.name.text == "State", !stateNames.isEmpty {
                continue
            }
            // A protocol it declares: what an object conforming to it takes.
            if let declaredProtocol = declaration.as(ProtocolDeclSyntax.self) {
                protocols.append(
                    Declared(
                        name: declaredProtocol.name.text,
                        requirements: declaredProtocol.memberBlock.members.compactMap {
                            $0.decl.as(FunctionDeclSyntax.self)
                        }.map {
                            $0.name.text + $0.signature.trimmedDescription
                        }))
                continue
            }
            // An event it announces: a function without a body, marked `@Event`.
            if let function = declaration.as(FunctionDeclSyntax.self), function.body == nil,
                function.attributes.contains(where: {
                    $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == RuntimeMacros.event
                })
            {
                announces.append(function.name.text + function.signature.trimmedDescription)
                continue
            }
            if let variable = declaration.as(VariableDeclSyntax.self),
                variable.bindings.allSatisfy({
                    $0.accessorBlock == nil && ($0.initializer != nil || Self.optional($0.typeAnnotation?.type))
                }),
                !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
            {
                for binding in variable.bindings {
                    let name = binding.pattern.trimmedDescription
                    // An optional with no value starts as `nil`, as in Swift.
                    let start = binding.initializer?.value.trimmedDescription ?? "nil"
                    if name == "state", !stateNames.isEmpty {
                        initial = String(start.split(separator: ".").last ?? "")
                        continue
                    }
                    var datum = Datum(
                        name: name, constant: variable.bindingSpecifier.tokenKind == .keyword(.let),
                        type: binding.typeAnnotation?.type.trimmedDescription, start: start)
                    datum.isPrivate = variable.modifiers.contains {
                        [.keyword(.private), .keyword(.fileprivate)].contains($0.name.tokenKind) && $0.detail == nil
                    }
                    // An object it follows is said as what it follows, not as data.
                    if variable.attributes.contains(where: {
                        $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == RuntimeMacros.subscribed
                    }) {
                        follows.append(datum)
                    } else {
                        data.append(datum)
                    }
                }
            } else if let function = declaration.as(FunctionDeclSyntax.self), function.name.text == "_check",
                let body = function.body
            {
                checks = Self.checks(in: body.statements)
            } else if let function = declaration.as(FunctionDeclSyntax.self),
                !function.modifiers.contains(where: {
                    $0.name.tokenKind == .keyword(.private) || $0.name.tokenKind == .keyword(.fileprivate)
                }),
                let body = function.body
            {
                let signature = function.name.text + function.signature.trimmedDescription
                if !stateNames.isEmpty, let cases = Self.stateSwitch(body.statements, values: stateValues) {
                    var covered: Set<String> = []
                    var otherwise: Handling?
                    for (names, handling) in cases {
                        guard let names else {
                            otherwise = handling
                            continue
                        }
                        for name in names {
                            covered.insert(name)
                            if let handling {
                                byState[name, default: []].append(Message(signature: signature, handling: handling))
                            }
                        }
                    }
                    // `default` takes the states no case names, unless it refuses.
                    if let otherwise {
                        for name in stateNames where !covered.contains(name) {
                            byState[name, default: []].append(Message(signature: signature, handling: otherwise))
                        }
                    }
                } else {
                    receive.append(Message(signature: signature, handling: Self.handling(body.statements)))
                }
            } else {
                helpers.append(declaration.trimmedDescription)
            }
        }
        // Settings come first, as the YAML has them.
        self.init(
            object: type, data: data.filter(\.constant) + data.filter { !$0.constant }, checks: checks,
            initial: stateNames.isEmpty ? nil : initial ?? stateNames.first,
            states: stateNames.map { State(name: $0, values: stateValues[$0], receive: byState[$0] ?? []) },
            receive: receive,
            helpers: helpers.isEmpty ? nil : helpers.joined(separator: "\n\n"))
        self.follows = follows
        self.announces = announces
        self.protocols = protocols
        // What it conforms to, as written: `Actor` is every object's, so it isn't said.
        self.conforms = actor.inheritance?.inheritedTypes.map(\.type.trimmedDescription).filter { $0 != "Actor" } ?? []
    }

    private static func optional(_ type: TypeSyntax?) -> Bool {
        guard let type else { return false }
        return type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self)
    }

    private static func handling(_ statements: CodeBlockItemListSyntax) -> Handling {
        (try? rules(of: statements)).map(Handling.rules) ?? .code(dedented(statements))
    }

    /// A body that's one `switch state`: each case's state names (`nil` for `default`) and how it
    /// handles the message there (`nil` when it refuses, with `fatalError`).
    private static func stateSwitch(_ statements: CodeBlockItemListSyntax, values: [String: String]) -> [(
        [String]?, Handling?
    )]? {
        guard statements.count == 1, let item = statements.first else { return nil }
        let found =
            item.item.as(ExpressionStmtSyntax.self)?.expression.as(SwitchExprSyntax.self)
            ?? item.item.as(SwitchExprSyntax.self)
        guard let switchState = found, ["state", "self.state"].contains(switchState.subject.trimmedDescription) else {
            return nil
        }
        var result: [([String]?, Handling?)] = []
        for element in switchState.cases {
            guard let switchCase = element.as(SwitchCaseSyntax.self) else { return nil }
            let body = switchCase.statements
            let only = body.count == 1 ? body.first!.item.trimmedDescription : nil
            let handling: Handling? =
                only?.hasPrefix("fatalError") == true
                ? nil
                : only == "break" ? .rules([Clause(when: nil, actions: [])]) : Self.handling(body)
            switch switchCase.label {
            case .default: result.append((nil, handling))
            case .case(let label):
                var names: [String] = []
                for item in label.caseItems {
                    guard let pattern = item.pattern.as(ExpressionPatternSyntax.self)?.expression else { return nil }
                    if let member = pattern.as(MemberAccessExprSyntax.self) {
                        names.append(member.declName.baseName.text)
                    } else if let call = pattern.as(FunctionCallExprSyntax.self),
                        let member = call.calledExpression.as(MemberAccessExprSyntax.self)
                    {
                        // `.waitingForOwner(let trip, let total)`: its values, bound by their labels.
                        let name = member.declName.baseName.text
                        let bound = call.arguments.map {
                            $0.expression.trimmedDescription.replacingOccurrences(of: "let ", with: "")
                        }
                        let labels = State(name: name, values: values[name], receive: []).labels
                        guard bound == labels else { return nil }
                        names.append(name)
                    } else {
                        return nil
                    }
                }
                result.append((names, handling))
            }
        }
        return result
    }

    /// `if !(condition) { return "condition" }`, for each check.
    private static func checks(in statements: CodeBlockItemListSyntax) -> [String] {
        statements.compactMap { item in
            guard let chain = ifChain(item), let condition = chain.conditions.first,
                case .expression(let expression) = condition.condition,
                let negated = expression.as(PrefixOperatorExprSyntax.self),
                let inner = negated.expression.as(TupleExprSyntax.self)
            else { return nil }
            return inner.elements.trimmedDescription
        }
    }

    struct NotRules: Error {
        let reason: String
    }

    /// A body as rules: `guard`s first, then actions, at most one `if … else if … else` chain,
    /// and actions after it. Actions before the chain run in every clause, and so do actions
    /// after it.
    static func rules(of statements: CodeBlockItemListSyntax) throws(NotRules) -> [Clause] {
        var early: [Clause] = []
        var before: [String] = []
        var chain: [Clause]?
        var after: [String] = []
        for item in statements {
            if let guardStatement = item.item.as(GuardStmtSyntax.self) {
                guard before.isEmpty, chain == nil, guardStatement.conditions.count == 1,
                    case .expression(let condition) = guardStatement.conditions.first!.condition
                else { throw NotRules(reason: "guard") }
                early.append(
                    Clause(
                        when: "!(\(condition.trimmedDescription))", actions: try actions(guardStatement.body.statements)
                    ))
            } else if let found = ifChain(item) {
                guard chain == nil else { throw NotRules(reason: "two ifs") }
                chain = try clauses(of: found)
            } else if chain == nil {
                before.append(try action(item))
            } else {
                after.append(try action(item))
            }
        }
        let body = (chain ?? [Clause(when: nil, actions: [])]).map {
            Clause(when: $0.when, actions: before + $0.actions + after)
        }
        return early + body
    }

    fileprivate static func ifChain(_ item: CodeBlockItemSyntax) -> IfExprSyntax? {
        if let expression = item.item.as(ExpressionStmtSyntax.self) {
            return expression.expression.as(IfExprSyntax.self)
        }
        return item.item.as(IfExprSyntax.self)
    }

    private static func clauses(of chain: IfExprSyntax) throws(NotRules) -> [Clause] {
        var result = [Clause(when: chain.conditions.trimmedDescription, actions: try actions(chain.body.statements))]
        switch chain.elseBody {
        case .ifExpr(let next)?: result += try clauses(of: next)
        case .codeBlock(let block)?: result.append(Clause(when: nil, actions: try actions(block.statements)))
        case nil: result.append(Clause(when: nil, actions: []))
        }
        return result
    }

    private static func actions(_ statements: CodeBlockItemListSyntax) throws(NotRules) -> [String] {
        var result: [String] = []
        for item in statements { result.append(try action(item)) }
        return result
    }

    /// One statement with no statement nested in it: an expression, a `return`, or a local
    /// `let`/`var`. A closure inside an expression is part of the expression.
    private static func action(_ item: CodeBlockItemSyntax) throws(NotRules) -> String {
        let node = item.item
        if ifChain(item) != nil { throw NotRules(reason: "nested if") }
        if let statement = node.as(ExpressionStmtSyntax.self) {
            if statement.expression.is(SwitchExprSyntax.self) { throw NotRules(reason: "switch") }
            return statement.trimmedDescription
        }
        if node.is(ReturnStmtSyntax.self) || node.is(ExprSyntax.self) { return node.trimmedDescription }
        if let variable = node.as(VariableDeclSyntax.self), variable.bindings.allSatisfy({ $0.accessorBlock == nil }) {
            return node.trimmedDescription
        }
        throw NotRules(reason: String(describing: node.syntaxNodeType))
    }

    /// Statements as written, without the indent they had in the method.
    private static func dedented(_ statements: CodeBlockItemListSyntax) -> String {
        let lines = statements.description.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let indent =
            lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - YAML

extension ObjectSource {
    /// The type as YAML: what it `conforms` to, `settings` and `data` as Swift bindings without
    /// `var`, what it `follows`, `checks`, the state it starts in, `receive` for every state and
    /// `states` for each, each message's rules as `when`/`do` and `otherwise`, or its `code`, what
    /// it `announces`, and the `protocols` it declares.
    public var yaml: String {
        get throws {
            var root: [(Node, Node)] = [(Node("object"), Node(object))]
            if !conforms.isEmpty { root.append((Node("conforms"), Node(conforms.map { Node($0) }))) }
            let settings = data.filter(\.constant)
            let held = data.filter { !$0.constant }
            if !settings.isEmpty { root.append((Node("settings"), Self.block(settings.map(\.written)))) }
            if !held.isEmpty { root.append((Node("data"), Self.block(held.map(\.written)))) }
            if !follows.isEmpty { root.append((Node("follows"), Self.block(follows.map(\.written)))) }
            if !checks.isEmpty { root.append((Node("checks"), Node(checks.map { Node($0) }))) }
            if let initial { root.append((Node("state"), Node(initial))) }
            if !receive.isEmpty { root.append((Node("receive"), Self.node(receive))) }
            if !states.isEmpty {
                root.append(
                    (
                        Node("states"),
                        Node.mapping(Node.Mapping(states.map { (Node($0.written), Self.node($0.receive)) }))
                    ))
            }
            if !announces.isEmpty { root.append((Node("announces"), Node(announces.map { Node($0) }))) }
            if !protocols.isEmpty {
                root.append(
                    (
                        Node("protocols"),
                        Node.mapping(
                            Node.Mapping(protocols.map { (Node($0.name), Node($0.requirements.map { Node($0) })) }))
                    ))
            }
            if let helpers { root.append((Node("helpers"), Node(helpers + "\n", Tag(.str), .literal))) }
            return try Yams.serialize(node: Node.mapping(Node.Mapping(root)), width: -1, allowUnicode: true)
        }
    }

    private static func node(_ messages: [Message]) -> Node {
        Node.mapping(
            Node.Mapping(
                messages.map { message in
                    let value: Node
                    switch message.handling {
                    case .code(let code):
                        value = Node.mapping(Node.Mapping([(Node("code"), Node(code + "\n", Tag(.str), .literal))]))
                    case .rules(let clauses) where clauses.count == 1 && clauses[0].when == nil:
                        value = block(clauses[0].actions)
                    case .rules(let clauses):
                        value = Node(
                            clauses.map { clause in
                                let actions = block(clause.actions)
                                guard let when = clause.when else {
                                    return Node.mapping(Node.Mapping([(Node("otherwise"), actions)]))
                                }
                                return Node.mapping(Node.Mapping([(Node("when"), Node(when)), (Node("do"), actions)]))
                            })
                    }
                    return (Node(message.signature), value)
                }))
    }

    /// Lines as a literal block: Swift as written, with nothing quoted.
    private static func block(_ lines: [String]) -> Node {
        lines.isEmpty ? Node("") : Node(lines.joined(separator: "\n") + "\n", Tag(.str), .literal)
    }
}
