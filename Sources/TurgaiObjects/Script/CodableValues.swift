import Doppel
import SwiftParser
import SwiftSyntax

/// The runtime's rule for values: what an object takes, gives back, announces or holds is sent and
/// kept as data, so it's `Codable`, as the checker resolved its type. Objects go as references.
public enum CodableValues {
    /// The rule, as the code's writer is told it.
    public static let rule =
        "Values its methods take and give back, its events carry, and its stored properties hold are Codable: the runtime sends and keeps them as data."

    /// Each value of the actor `type` in `code` that isn't `Codable`, at its line, in Swift's words.
    static func problems(in code: String, type: String, declarations: Declarations) -> [CodeProblem] {
        guard case .actor(let fields, let methods, _, _)? = declarations[type] else { return [] }
        let places = Places(code: code, type: type)
        var checking = Checking(declarations: declarations)
        var problems: [CodeProblem] = []
        for method in methods {
            let written = "\(method.name)(\(method.parameters.map { "\($0.label ?? "_"):" }.joined()))"
            for parameter in method.parameters {
                guard let part = checking.notCodable(parameter.type) else { continue }
                problems.append(
                    CodeProblem(
                        line: places.method(method)?.line, span: places.method(method)?.parameters[parameter.name],
                        message(
                            "parameter '\(parameter.name)' of type '\(parameter.type)' in '\(written)'", parameter.type,
                            part)))
            }
            if let part = checking.notCodable(method.result) {
                problems.append(
                    CodeProblem(
                        line: places.method(method)?.line, span: places.method(method)?.result,
                        message("result type '\(method.result)' of '\(written)'", method.result, part)))
            }
        }
        for field in fields {
            guard let part = checking.notCodable(field.type) else { continue }
            problems.append(
                CodeProblem(
                    line: places.fields[field.name]?.line, span: places.fields[field.name]?.span,
                    message("stored property '\(field.name)' of type '\(field.type)'", field.type, part)))
        }
        // A type that says it's `Codable` holds only what is, as Swift makes it.
        for name in checking.unmet.sorted() {
            problems.append(
                CodeProblem(
                    line: places.types[name], span: nil, "type '\(name)' does not conform to protocol 'Codable'"))
        }
        return problems
    }

    /// What's wrong with `value`, whose part `part` isn't `Codable`.
    private static func message(_ value: String, _ type: SwiftType, _ part: SwiftType) -> String {
        "\(value) does not conform to 'Codable'" + (part == type ? "" : ": '\(part)' doesn't")
    }

    private struct Checking {
        let declarations: Declarations
        /// The types that say they're `Codable` and hold something that isn't.
        var unmet: Set<String> = []
        /// The types read, so one that holds itself is read once.
        private var read: Set<String> = []

        init(declarations: Declarations) {
            self.declarations = declarations
        }

        /// The first part of `type` that isn't `Codable`, `nil` when all of it is.
        mutating func notCodable(_ type: SwiftType) -> SwiftType? {
            switch type {
            case .int, .double, .bool, .string, .fixedInteger, .void, .never:
                return nil
            // The checker said what's wrong with it already.
            case .unresolved:
                return nil
            case .optional(let wrapped), .array(let wrapped):
                return notCodable(wrapped)
            // Its keys and values are carried as `Codable` writes them.
            case .dictionary(let key, let value):
                return notCodable(key) ?? notCodable(value)
            case .existential:
                // Any object, as the module declares `Object`, or one conforming to a protocol
                // an object declares, goes as a reference to it.
                return SwiftTypeSchema.isAnyObject(type) || SwiftTypeSchema.conformed(type, in: declarations) != nil
                    ? nil : type
            case .named(let name, let arguments):
                if ["Date", "Decimal", "UUID", "URL"].contains(name) { return nil }
                if name == "Set" { return arguments.first.flatMap { notCodable($0) } }
                switch declarations[name] {
                // An object goes as a reference to it: of an actor type, or conforming to a protocol.
                case .actor?, .protocol?:
                    return nil
                case .structure(let fields, let conformances, _)?:
                    guard conformances.contains("Codable") else { return type }
                    meets(name, fields.map(\.type))
                case .enumeration(let cases, let conformances, _)?:
                    guard conformances.contains("Codable") else { return type }
                    meets(name, cases.flatMap { $0.values.map(\.type) })
                case nil:
                    return type
                }
                for argument in arguments {
                    if let part = notCodable(argument) { return part }
                }
                return nil
            case .character, .tuple, .function, .parameter, .inout, .dynamic, .metatype:
                return type
            }
        }

        /// Records `name`, which says it's `Codable`, as unmet when what it holds isn't.
        private mutating func meets(_ name: String, _ held: [SwiftType]) {
            guard read.insert(name).inserted else { return }
            if held.contains(where: { notCodable($0) != nil }) { unmet.insert(name) }
        }
    }

    /// Where the code declares what's checked: each method's line, with its parameters' and
    /// result's types as written, each stored property's, and each type's.
    private struct Places {
        struct Method {
            let line: Int
            let parameters: [String: String]
            let result: String?
        }

        var methods: [String: [(labels: [String?], method: Method)]] = [:]
        var fields: [String: (line: Int, span: String?)] = [:]
        var types: [String: Int] = [:]

        init(code: String, type: String) {
            let file = Parser.parse(source: code)
            let lines = SourceLocationConverter(fileName: "", tree: file)
            func line(_ node: some SyntaxProtocol) -> Int {
                lines.location(for: node.positionAfterSkippingLeadingTrivia).line
            }
            final class Types: SyntaxVisitor {
                var found: [(name: String, node: Syntax)] = []
                var outer: [String] = []
                override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
                    enter(node.name.text, node)
                }
                override func visitPost(_ node: StructDeclSyntax) { outer.removeLast() }
                override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node) }
                override func visitPost(_ node: EnumDeclSyntax) { outer.removeLast() }
                override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
                    enter(node.name.text, node)
                }
                override func visitPost(_ node: ActorDeclSyntax) { outer.removeLast() }
                private func enter(_ name: String, _ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
                    outer.append(name)
                    found.append((outer.joined(separator: "."), Syntax(node)))
                    return .visitChildren
                }
            }
            let visitor = Types(viewMode: .sourceAccurate)
            visitor.walk(file)
            for (name, node) in visitor.found { types[name] = line(node) }
            guard let actor = visitor.found.first(where: { $0.name == type })?.node.as(ActorDeclSyntax.self) else {
                return
            }
            for member in actor.memberBlock.members {
                if let function = member.decl.as(FunctionDeclSyntax.self) {
                    let parameters = function.signature.parameterClause.parameters
                    let method = Method(
                        line: line(function),
                        parameters: Dictionary(
                            parameters.map { (($0.secondName ?? $0.firstName).text, $0.type.trimmedDescription) },
                            uniquingKeysWith: { first, _ in first }),
                        result: function.signature.returnClause?.type.trimmedDescription)
                    methods[function.name.text, default: []].append(
                        (parameters.map { $0.firstName.text == "_" ? nil : $0.firstName.text }, method))
                } else if let variable = member.decl.as(VariableDeclSyntax.self) {
                    for binding in variable.bindings {
                        guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                            continue
                        }
                        fields[name] = (
                            line(variable),
                            binding.typeAnnotation?.type.trimmedDescription
                                ?? binding.initializer?.value.trimmedDescription
                        )
                    }
                }
            }
        }

        func method(_ method: Declarations.Method) -> Method? {
            methods[method.name]?.first { $0.labels == method.parameters.map(\.label) }?.method
        }
    }
}
