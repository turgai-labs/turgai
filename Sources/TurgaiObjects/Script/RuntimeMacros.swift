import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros

/// The macros an object's code can use, which the runtime provides: real Swift macros, expanded
/// in-process before the code runs. What they expand to calls the runtime, which does the rest:
/// announcing, subscribing, delivering, and keeping it all across restarts.
public enum RuntimeMacros {
    /// The attribute of a method the runtime gives a body: announcing an event.
    public static let event = "Event"
    /// The attribute of a property whose object the actor follows the events of.
    public static let subscribed = "Subscribed"

    static let all: [String: Macro.Type] = [event: EventMacro.self, subscribed: SubscribedMacro.self]

    /// The builtin an `@Event` method's body calls, with the event's name and its values.
    static let announce = "__announce"

    /// `code` with the runtime's macros expanded: what runs. A `@Subscribed` property declared with
    /// its type and no value holds the object of that type, which the runtime resolves, as SwiftUI
    /// fills in `@Environment`.
    static func expanding(_ code: String) -> String {
        let resolved = Resolving().rewrite(Parser.parse(source: code))
        return resolved.expand(macros: all, contextGenerator: { _ in ExpansionContext() }).description
    }

    /// Gives each `@Subscribed` property declared with a type and no value the object of that type.
    private final class Resolving: SyntaxRewriter {
        override func visit(_ node: VariableDeclSyntax) -> DeclSyntax {
            guard ObjectShape.carries(node.attributes, RuntimeMacros.subscribed) else { return super.visit(node) }
            var declaration = node
            declaration.bindings = PatternBindingListSyntax(node.bindings.map { binding in
                guard binding.initializer == nil, let type = binding.typeAnnotation?.type else { return binding }
                let object = (type.as(OptionalTypeSyntax.self)?.wrappedType ?? type).trimmed
                // The object, in place of its type, which only the runtime knows.
                var resolved = binding
                resolved.typeAnnotation = nil
                resolved.pattern = resolved.pattern.trimmed
                resolved.initializer = InitializerClauseSyntax(
                    equal: .equalToken(leadingTrivia: .space, trailingTrivia: .space), value: ExprSyntax("\(object)()"))
                return resolved
            })
            return DeclSyntax(declaration)
        }
    }

    /// The macros as Swift declares them, for whoever writes an object's code.
    public static let declared = """
        Macros:
          @Event: a function without a body. Calling it sends that event to subscribers.
          @Subscribed: a property holding an object. Each of the object's events calls this actor's function of the same name, with its values.
        """
}

/// `@Event func cupAdded(count: Int)`: calling it announces `cupAdded` with `count`.
struct EventMacro: BodyMacro {
    static func expansion(
        of node: AttributeSyntax, providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else { return [] }
        let values = function.signature.parameterClause.parameters.map { parameter in
            let name = (parameter.secondName ?? parameter.firstName).text
            return "\"\(name)\": \(name)"
        }
        let dictionary = values.isEmpty ? "[:]" : "[\(values.joined(separator: ", "))]"
        return ["\(raw: RuntimeMacros.announce)(\(literal: function.name.text), \(raw: dictionary))"]
    }
}

/// `@Subscribed var shop = Shop()`: the property stays as it is. The runtime reads the attribute
/// from the code, and follows the object the property holds.
struct SubscribedMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

/// What an expansion needs from where it happens: nothing it reports, since the code was checked
/// before it's expanded.
private final class ExpansionContext: MacroExpansionContext {
    private var unique = 0

    func makeUniqueName(_ name: String) -> TokenSyntax {
        unique += 1
        return .identifier("__\(name)\(unique)")
    }

    func diagnose(_ diagnostic: SwiftDiagnostics.Diagnostic) {}

    func location(
        of node: some SyntaxProtocol, at position: PositionInSyntaxNode, filePathMode: SourceLocationFilePathMode
    ) -> AbstractSourceLocation? {
        nil
    }

    var lexicalContext: [Syntax] { [] }
}
