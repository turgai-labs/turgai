import SwiftParser
import SwiftSyntax

/// How an object's stored properties get their values: each from its initial value, since the
/// object is made with its id alone, as a distributed actor is with its actor system. An `init`
/// other than `init(id: String)` is never called, so what it would set needs an initial value.
enum StartingValues {
    /// What's wrong with how a stored property gets its value, as Swift would say it.
    enum Problem: CustomStringConvertible {
        /// An `init` other than `init(id: String)`: nothing calls it.
        case neverCalled
        /// A stored property with no initial value, by its name.
        case needsInitialValue(String)

        var description: String {
            switch self {
            case .neverCalled: "is never called"
            case .needsInitialValue(let name): "stored property '\(name)' needs an initial value"
            }
        }
    }

    static func problems(in code: String, type: String) -> [CodeProblem] {
        let file = Parser.parse(source: code)
        let lines = SourceLocationConverter(fileName: "", tree: file)
        func line(_ node: some SyntaxProtocol) -> Int {
            lines.location(for: node.positionAfterSkippingLeadingTrivia).line
        }
        guard
            let actor = file.statements.lazy.compactMap({ $0.item.as(ActorDeclSyntax.self) }).first(where: {
                $0.name.text == type
            })
        else { return [] }
        // Each stored property without an initial value, by name: an optional `var` starts as
        // `nil`, as Swift has it.
        var unset: [String: VariableDeclSyntax] = [:]
        var order: [String] = []
        for variable in actor.memberBlock.members.compactMap({ $0.decl.as(VariableDeclSyntax.self) }) {
            let isVar = variable.bindingSpecifier.tokenKind == .keyword(.var)
            for binding in variable.bindings where binding.initializer == nil && binding.accessorBlock == nil {
                if isVar, binding.typeAnnotation?.type.is(OptionalTypeSyntax.self) == true { continue }
                let name = binding.pattern.trimmedDescription
                unset[name] = variable
                order.append(name)
            }
        }
        let initializers = actor.memberBlock.members.compactMap { $0.decl.as(InitializerDeclSyntax.self) }
        var problems: [CodeProblem] = []
        for initializer in initializers where !isMadeWithItsID(initializer) {
            problems.append(
                CodeProblem(
                    line: line(initializer), span: "init\(initializer.signature.trimmedDescription)",
                    Problem.neverCalled.description, phrasing: .statement))
        }
        // Made with `init(id:)` alone, each one it leaves unset needs its initial value.
        if !initializers.contains(where: isMadeWithItsID) {
            for name in order {
                guard let variable = unset[name] else { continue }
                problems.append(
                    CodeProblem(
                        line: line(variable), span: variable.trimmedDescription,
                        Problem.needsInitialValue(name).description))
            }
        }
        return problems
    }

    /// Whether `initializer` is an object's: `init(id: String)`.
    static func isMadeWithItsID(_ initializer: InitializerDeclSyntax) -> Bool {
        let parameters = initializer.signature.parameterClause.parameters
        guard parameters.count == 1, let parameter = parameters.first else { return false }
        return parameter.firstName.text == ObjectModule.idLabel && parameter.secondName == nil
            && parameter.type.trimmedDescription == "String"
    }
}
