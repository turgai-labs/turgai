import SwiftParser
import SwiftSyntax

/// The objects code names by id are ones that exist: an id is never made up. A type with
/// objects is named by one of their ids; a type with none yet is named by a new one, which
/// makes it.
enum ExistingObjects {
    /// Each `Type(id: "…")` in `script` whose type has objects and whose id isn't one of theirs,
    /// at its line, with the ids there are.
    static func problems(in script: Script) -> [CodeProblem] {
        let file = Parser.parse(source: script.code)
        let lines = SourceLocationConverter(fileName: "", tree: file)
        final class Named: SyntaxVisitor {
            var calls: [(call: FunctionCallExprSyntax, type: String, id: String)] = []

            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if let type = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
                    node.arguments.count == 1, let argument = node.arguments.first,
                    argument.label?.text == ObjectModule.idLabel,
                    let literal = argument.expression.as(StringLiteralExprSyntax.self),
                    let id = literal.representedLiteralValue
                {
                    calls.append((node, type, id))
                }
                return .visitChildren
            }
        }
        let named = Named(viewMode: .sourceAccurate)
        named.walk(file)
        return named.calls.compactMap { call, type, written in
            let ids = script.uses.ids(of: type).map(\.rawValue)
            // As the runtime keeps ids: the id written, as a handle.
            guard !ids.isEmpty, !ids.contains(ObjectNames.handle(for: written)) else { return nil }
            return CodeProblem(
                line: lines.location(for: call.positionAfterSkippingLeadingTrivia).line,
                span: call.trimmedDescription,
                "`\(type)` has no object with id `\(written)`; its objects: "
                    + ids.map { "`\($0)`" }.joined(separator: ", "))
        }
    }
}
