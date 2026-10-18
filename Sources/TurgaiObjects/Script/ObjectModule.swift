import SwiftParser
import SwiftSyntax

/// An object's code as the Swift module it is: the module it imports, its runtime, and its own
/// file, all plain Swift. What's Turgai's is said in Swift here: the spec's objects as actors, the
/// objects reached by name as constants, and the runtime's macros as they expand, on the lines
/// they're written, so a line of the module's object file is the line of the code.
///
/// Turgai's Swift goes beyond Swift in one way: another object of a type the code doesn't declare
/// is an `Object`, and a method called on one is a message.
public struct ObjectModule: Sendable {
    /// A file of the module: its name, and its code.
    public struct File: Sendable, Hashable {
        public let name: String
        public let code: String
    }

    /// The file with the object's own code.
    public static let objectFile = "Object.swift"

    public let files: [File]

    public init(_ script: Script) {
        let declared = Set(Self.typeNames(in: script.uses.interface.source))
        var runtime = [
            "/// Another object, of a type this code doesn't declare: what's called on it is a message.",
            "typealias Object = any Actor",
            "",
            "/// An object reached by a name whose type isn't declared.",
            "actor Undeclared {}",
            "",
            "/// What an `@\(RuntimeMacros.event)` function's body calls: the event, announced with its values.",
            "func \(RuntimeMacros.announce)(_ event: String, _ values: [String: any Sendable]) {}",
            "",
            "// The objects the code reaches by name.",
        ]
        for name in Set(script.uses.names.keys).union(script.namedObjects).sorted() {
            if let type = script.uses.names[name], declared.contains(type) {
                runtime.append("let \(name) = \(type)()")
            } else {
                runtime.append("let \(name): Object = Undeclared()")
            }
        }
        files = [
            File(name: "Objects.swift", code: Self.stubbed(script.uses.interface.source)),
            File(name: "Runtime.swift", code: runtime.joined(separator: "\n") + "\n"),
            File(name: Self.objectFile, code: Self.expanded(script.code)),
        ]
    }

    /// The files the code is given: all but its own.
    public var given: [File] { files.filter { $0.name != Self.objectFile } }

    static func typeNames(in source: String) -> [String] {
        Parser.parse(source: source).statements.compactMap { item in
            if let actor = item.item.as(ActorDeclSyntax.self) { return actor.name.text }
            if let structure = item.item.as(StructDeclSyntax.self) { return structure.name.text }
            if let enumeration = item.item.as(EnumDeclSyntax.self) { return enumeration.name.text }
            return nil
        }
    }

    /// The spec's declarations with bodies Swift takes: each function and property without one is
    /// given one, which never runs, and its events are plain functions.
    static func stubbed(_ source: String) -> String {
        Stubbing().rewrite(Parser.parse(source: source)).description
    }

    private final class Stubbing: SyntaxRewriter {
        override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
            var function = node
            function.attributes = AttributeListSyntax(node.attributes.filter { !ObjectModule.isRuntimeMacro($0) })
            // Its line and indent, which an attribute taken away took with it.
            function.leadingTrivia = node.leadingTrivia
            if function.body == nil {
                function.body = CodeBlockSyntax(
                    leftBrace: .leftBraceToken(leadingTrivia: .space), statements: ["fatalError()"], rightBrace: .rightBraceToken())
            }
            return DeclSyntax(function)
        }

        override func visit(_ node: AccessorDeclSyntax) -> DeclSyntax {
            guard node.body == nil else { return DeclSyntax(node) }
            var accessor = node
            accessor.body = CodeBlockSyntax(
                leftBrace: .leftBraceToken(leadingTrivia: .space), statements: ["fatalError()"],
                rightBrace: .rightBraceToken(leadingTrivia: .space))
            return DeclSyntax(accessor)
        }
    }

    static func isRuntimeMacro(_ element: AttributeListSyntax.Element) -> Bool {
        guard let attribute = element.as(AttributeSyntax.self) else { return false }
        let name = attribute.attributeName.trimmedDescription
        return name == RuntimeMacros.event || name == RuntimeMacros.subscribed
    }

    /// The code with the runtime's macros expanded where they're written, keeping its lines: an
    /// `@Event` function announces, and a `@Subscribed` property holds the object of its type.
    static func expanded(_ code: String) -> String {
        let file = Parser.parse(source: code)
        var edits: [(range: Range<Int>, text: String)] = []
        for token in file.tokens(viewMode: .sourceAccurate) {
            guard token.tokenKind == .atSign, let attribute = token.parent?.as(AttributeSyntax.self),
                isRuntimeMacro(.attribute(attribute))
            else { continue }
            edits.append((attribute.positionAfterSkippingLeadingTrivia.utf8Offset..<attribute.endPositionBeforeTrailingTrivia.utf8Offset, ""))
            let declaration = attribute.parent?.parent
            if let function = declaration?.as(FunctionDeclSyntax.self), function.body == nil {
                let values = function.signature.parameterClause.parameters.map { parameter in
                    let name = (parameter.secondName ?? parameter.firstName).text
                    return "\"\(name)\": \(name)"
                }
                let end = function.signature.endPositionBeforeTrailingTrivia.utf8Offset
                edits.append(
                    (end..<end, " { \(RuntimeMacros.announce)(\"\(function.name.text)\", [\(values.isEmpty ? ":" : values.joined(separator: ", "))]) }"))
            }
            if let variable = declaration?.as(VariableDeclSyntax.self) {
                for binding in variable.bindings where binding.initializer == nil {
                    guard let annotation = binding.typeAnnotation else { continue }
                    let type = (annotation.type.as(OptionalTypeSyntax.self)?.wrappedType ?? annotation.type).trimmedDescription
                    let range = annotation.positionAfterSkippingLeadingTrivia.utf8Offset..<annotation.endPositionBeforeTrailingTrivia.utf8Offset
                    edits.append((range, " = \(type)()"))
                }
            }
        }
        var bytes = Array(code.utf8)
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            bytes.replaceSubrange(edit.range, with: Array(edit.text.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
