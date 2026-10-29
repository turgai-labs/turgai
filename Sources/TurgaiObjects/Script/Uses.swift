import DiscoverableActors
import Foundation
import SwiftParser
import SwiftSyntax

/// What an object's code was written against: the other objects around it and the values they
/// send and take, as the module its code imports, and the objects that exist. It's kept
/// with the code, so the code runs as it was checked. Calls stay messages, by name, to whichever
/// object is there: this is what the code expects, never a link.
public struct Uses: Codable, Sendable, Equatable {
    /// The objects and their values, as the module the code imports declares them.
    public let interface: ModuleInterface
    /// The objects that exist, each id's type: what `Type(id:)` reaches.
    public let objects: [ObjectIdentity: String]
    /// The types whose objects last, as virtual actors: the same object, by the same id, after
    /// every restart, so code names them by id, keeps them and follows them.
    public let lasting: Set<String>

    public init(interface: ModuleInterface, objects: [ObjectIdentity: String], lasting: Set<String>) {
        self.interface = interface
        self.objects = objects
        self.lasting = lasting
    }

    /// The ids of the objects of `type` that exist, in order.
    public func ids(of type: String) -> [ObjectIdentity] {
        objects.filter { $0.value == type }.map(\.key).sorted { $0.rawValue < $1.rawValue }
    }

    /// Nothing from other objects.
    public static let nothing = Uses(
        interface: ModuleInterface(name: Uses.module, source: ""), objects: [:], lasting: [])

    /// The module objects' code imports.
    public static let module = "Objects"

    /// The type of any object, as the module declares it.
    public static let anyObject = "Object"

    /// The namespace of the tools object code calls: `Tools.Http.send`.
    public static let tools = "Tools"

    /// The types whose values are other objects: the actors the module declares, and any object.
    public var objectTypes: Set<String> {
        Set(interface.actors(events: []).map(\.name)).union([Self.anyObject])
    }
}

// MARK: The spec, as Swift declares it

extension Uses {
    /// An object, as the spec renders it: the type code reaches it as, what it is, and whether
    /// what it publishes can be read, as a built-in object's can.
    public struct Object: Sendable {
        public let description: ObjectDescription
        public let publishes: Bool

        /// The type code reaches it as: the one it says it is.
        public var type: String { description.type }

        public init(description: ObjectDescription, publishes: Bool) {
            self.description = description
            self.publishes = publishes
        }
    }

    /// The module `objects` make, as Swift declares it: each object an actor, with its methods,
    /// what it publishes and its events, and the structs and enums their values are. The types of
    /// `own`, the object whose code imports it, are left out: its code declares them.
    public static func interface(of objects: [Object], tools: [ToolsAPI.Tool] = [], except own: String? = nil)
        -> ModuleInterface
    {
        var schemas: [JSONValue] = []
        var actors: [String] = []
        if let declared = declaration(ofTools: tools, schemas: &schemas) { actors.append(declared) }
        for object in objects {
            var lines = documented(object.description.description.map(JSONValue.string), indent: "")
            lines.append("actor \(object.type) {")
            if object.publishes {
                for (name, property) in object.description.properties.sorted(by: { $0.key < $1.key })
                where property[Script.privateKey] != .bool(true) {
                    // What can't be written in Swift isn't declared: code can't use it as it is.
                    guard let type = property.swiftType else { continue }
                    lines += documented(property["description"], indent: "    ")
                    // Read from another actor's node: awaited, and tried, whatever it holds.
                    lines.append("    var \(name): \(type) { get async throws }")
                    schemas.append(property)
                }
            }
            for (name, action) in object.description.actions.sorted(by: { $0.key < $1.key }) {
                guard let parameters = parameters(of: action.input) else { continue }
                let output: String?? = action.output.map(\.swiftType)
                if case .some(nil) = output { continue }
                lines += documented(action.description.map(JSONValue.string), indent: "    ")
                lines += documentedParameters(of: action.input, indent: "    ")
                // Called on another actor's node: awaited, and tried, whatever its code declares.
                lines.append(
                    "    func \(ActionKeys.baseName(of: name))(\(written(parameters))) async throws"
                        + (output.flatMap { $0 }.map { " -> \($0)" } ?? ""))
                if let input = action.input { schemas.append(input) }
                if let output = action.output { schemas.append(output) }
            }
            // The protocols it declares, within it, as its code declares them: `Shop.RefundManager` is
            // `RefundManager` in `Shop`. A requirement is a message, so it's awaited and tried.
            for (name, declared) in object.description.protocols.sorted(by: { $0.key < $1.key }) {
                let local = name.hasPrefix("\(object.type).") ? String(name.dropFirst(object.type.count + 1)) : name
                lines += documented(declared.description.map(JSONValue.string), indent: "    ")
                lines.append("    protocol \(local) {")
                for (requirement, action) in declared.requirements.sorted(by: { $0.key < $1.key }) {
                    guard let parameters = parameters(of: action.input) else { continue }
                    let output: String?? = action.output.map(\.swiftType)
                    if case .some(nil) = output { continue }
                    lines += documented(action.description.map(JSONValue.string), indent: "        ")
                    lines.append(
                        "        func \(requirement)(\(written(parameters))) async throws"
                            + (output.flatMap { $0 }.map { " -> \($0)" } ?? ""))
                    if let input = action.input { schemas.append(input) }
                    if let output = action.output { schemas.append(output) }
                }
                lines.append("    }")
            }
            for (name, event) in object.description.events.sorted(by: { $0.key < $1.key }) {
                // As a function, named as Swift names one: `TrackChanged`'s is `trackChanged`.
                let function = name.prefix(1).lowercased() + name.dropFirst()
                guard let parameters = parameters(of: event.data) else { continue }
                lines.append("    @\(RuntimeMacros.event) func \(function)(\(written(parameters)))")
                // Its handler takes its values, never the event itself: the types are its values'.
                if case .object(let values)? = event.data["properties"] { schemas += values.values }
            }
            lines.append("}")
            actors.append(lines.joined(separator: "\n"))
        }
        let values = declarations(of: schemas, except: own)
        return ModuleInterface(
            name: module, source: (actors + (values.isEmpty ? [] : [values])).joined(separator: "\n\n"))
    }

    /// The tools object code calls, as Swift declares them: `enum Tools`, with an enum in it for each
    /// tool, `Tools.Http`, and its functions, each static, awaited and tried. A function whose
    /// values can't be written in Swift isn't declared; `nil` when none is.
    static func declaration(ofTools tools: [ToolsAPI.Tool], schemas: inout [JSONValue]) -> String? {
        var lines: [String] = []
        for tool in tools.sorted(by: { $0.name < $1.name }) {
            var functions: [String] = []
            for function in tool.functions.sorted(by: { $0.name < $1.name }) {
                guard let call = call(of: function) else { continue }
                functions += documented(function.description.map(JSONValue.string), indent: "        ")
                functions.append("        static func \(call)")
                schemas += [function.input, function.output]
            }
            guard !functions.isEmpty else { continue }
            lines += documented(tool.description.map(JSONValue.string), indent: "    ")
            lines += ["    enum \(tool.name) {"] + functions + ["    }"]
        }
        guard !lines.isEmpty else { return nil }
        return (["enum \(Self.tools) {"] + lines + ["}"]).joined(separator: "\n")
    }

    /// A tool's function as code calls it: the value it takes, named by its type, and the value
    /// it gives, `send(_ httpRequest: HttpRequest) async throws -> HttpResponse`; `nil` when either
    /// can't be written in Swift.
    public static func call(of function: ToolsAPI.Function) -> String? {
        guard let input = function.input.typeName, let output = function.output.swiftType else { return nil }
        let own = input.split(separator: ".").last.map(String.init) ?? input
        let name = own.prefix(1).lowercased() + own.dropFirst()
        return "\(function.name)(_ \(name): \(input)) async throws -> \(output)"
    }

    /// The parameters a schema's values are, as Swift declares them, in the order they're
    /// declared: each with its label, `nil` for `_`, its name and its type, an optional where
    /// it may be left out; `nil` when one's type can't be written.
    public static func parameters(of schema: JSONValue?) -> [(label: String?, name: String, type: String)]? {
        guard case .object(let properties)? = schema?["properties"] else { return [] }
        let required = Set(schema?["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let order =
            schema?["x-order"]?.arrayValue?.compactMap(\.stringValue)
            ?? properties.keys.filter(required.contains).sorted()
            + properties.keys.filter { !required.contains($0) }.sorted()
        var parameters: [(label: String?, name: String, type: String)] = []
        for name in order {
            guard let property = properties[name] else { continue }
            // Its label as its code declares it, `_` for none; an object that doesn't say is
            // called with its parameters' names.
            let label: String? =
                switch property[ObjectShape.Message.labelKey] {
                case .string("_")?: nil
                case .string(let label)?: label
                default: name
                }
            guard let type = property.declaredType(optional: !required.contains(name)) else { return nil }
            parameters.append((label, name, type))
        }
        return parameters
    }

    /// Parameters as a declaration lists them: `from ann: Ann, _ amount: Int`.
    static func written(_ parameters: [(label: String?, name: String, type: String)]) -> String {
        parameters.map { parameter in
            (parameter.label == parameter.name ? parameter.name : "\(parameter.label ?? "_") \(parameter.name)")
                + ": \(parameter.type)"
        }.joined(separator: ", ")
    }
}

// MARK: The values, in words

extension Uses {
    /// The structs and enums the code imports, each in a few lines, as the writer is told them:
    /// what it is, then its fields or its cases, each with its type as Swift writes it. Words,
    /// never declarations to copy.
    public var valuesInWords: [String] {
        interface.valueDeclarations.compactMap { (name: String, declaration: DeclSyntax) -> String? in
            if let structure = declaration.as(StructDeclSyntax.self) { return Self.inWords(structure, named: name) }
            if let enumeration = declaration.as(EnumDeclSyntax.self) { return Self.inWords(enumeration, named: name) }
            return nil
        }
    }

    /// A structure: what it is, then each field with its type.
    private static func inWords(_ structure: StructDeclSyntax, named name: String) -> String {
        var lines: [String] = [titled(name, summary(structure.leadingTrivia)), "  Fields:"]
        for member in structure.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            let said: String = Self.said(summary(variable.leadingTrivia))
            for binding in variable.bindings {
                let type: String = binding.typeAnnotation?.type.trimmedDescription ?? "Any"
                lines.append("    \(binding.pattern.trimmedDescription): \(type)\(said)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// An enumeration: what it is, then each case with its values.
    private static func inWords(_ enumeration: EnumDeclSyntax, named name: String) -> String {
        var lines: [String] = [titled(name, summary(enumeration.leadingTrivia)) + " One of:"]
        for member in enumeration.memberBlock.members {
            guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            let said: String = Self.said(summary(cases.leadingTrivia))
            for element in cases.elements {
                lines.append("    \(element.name.text)\(values(of: element))\(said)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A case's associated values, as Swift writes them: none, or each with its label and type.
    private static func values(of element: EnumCaseElementSyntax) -> String {
        guard let clause = element.parameterClause else { return "" }
        let parameters: [String] = clause.parameters.map { (parameter: EnumCaseParameterSyntax) -> String in
            let label: String = parameter.firstName.map { (name: TokenSyntax) -> String in "\(name.text): " } ?? ""
            return label + parameter.type.trimmedDescription
        }
        return "(\(parameters.joined(separator: ", ")))"
    }

    private static func titled(_ name: String, _ summary: String?) -> String {
        "- \(name)" + (summary.map { ": \(lowercasedFirst($0))" } ?? "")
    }

    private static func said(_ summary: String?) -> String {
        summary.map { ", \(lowercasedFirst($0))" } ?? ""
    }

    private static func lowercasedFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }

    /// What a declaration's documentation says, from its `///` lines.
    private static func summary(_ trivia: Trivia) -> String? {
        let lines = trivia.compactMap { piece -> String? in
            if case .docLineComment(let text) = piece {
                String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                nil
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

// MARK: Declaring types from their schemas

extension Uses {
    /// The Swift declarations of the types `schemas` name, and of the types those name in turn,
    /// each once, as Swift declares them: a structure's fields in the order they're declared, an
    /// enumeration's cases with their raw values or their associated values.
    /// What a value is when code leaves it out, as its declaration says: its default, or `nil` for
    /// one that may be left out.
    static func swiftDefault(of field: JSONValue, required: Bool) -> String {
        if case .string(let value)? = field[Discovery.swiftDefaultKey] { return " = \(value)" }
        return required ? "" : " = nil"
    }

    static func declarations(of schemas: [JSONValue], except own: String? = nil) -> String {
        var named: [(name: String, schema: JSONValue)] = []
        func collect(_ schema: JSONValue) {
            // A type of the object `own`, which its code declares itself, isn't declared again.
            if let name = schema.typeName, own.map({ name != $0 && !name.hasPrefix("\($0).") }) ?? true,
                !named.contains(where: { $0.name == name })
            {
                named.append((name, schema))
            }
            for child in schema.children { collect(child) }
        }
        for schema in schemas { collect(schema) }
        return named.compactMap { name, schema in
            // A nested type is declared in an extension of the type it's in, as Swift lets it be.
            guard let dot = name.lastIndex(of: ".") else { return declaration(of: schema, named: name) }
            return declaration(of: schema, named: String(name[name.index(after: dot)...])).map { declared in
                "extension \(name[..<dot]) {\n"
                    + declared.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }.joined(
                        separator: "\n") + "\n}"
            }
        }.joined(separator: "\n\n")
    }

    /// One type's declaration, read from its schema.
    static func declaration(of schema: JSONValue, named name: String) -> String? {
        var lines = documented(schema["description"], indent: "")
        // An enumeration with associated values: one option per case, as `Codable` writes it.
        if case .array(let options)? = schema["oneOf"],
            options.allSatisfy({ $0["properties"]?.objectValue?.count == 1 && $0["const"] == nil })
        {
            lines.append("enum \(name): Codable {")
            for option in options {
                guard let (caseName, values) = option["properties"]?.objectValue?.first else { continue }
                lines += documented(values["description"], indent: "    ")
                var associated: [String] = []
                for (label, field) in ordered(values) {
                    // A type with a value that can't be written isn't declared.
                    guard let type = field.declaredType(optional: !required(values).contains(label)) else { return nil }
                    associated.append(
                        (label.hasPrefix("_") ? "" : "\(label): ") + type
                            + Self.swiftDefault(of: field, required: required(values).contains(label)))
                }
                lines.append(
                    "    case \(caseName)" + (associated.isEmpty ? "" : "(\(associated.joined(separator: ", ")))"))
            }
            lines.append("}")
            return lines.joined(separator: "\n")
        }
        // An enumeration with raw values, its cases as Swift names them.
        if case .array(let names)? = schema["x-enum-varnames"] {
            let values: [JSONValue] =
                if case .array(let values)? = schema["enum"] { values } else {
                    (schema["oneOf"]?.arrayValue ?? []).map { $0["const"] ?? .null }
                }
            let descriptions = (schema["oneOf"]?.arrayValue ?? []).map(\.["description"])
            let raw = schema["type"] == "integer" ? "Int" : "String"
            lines.append("enum \(name): \(raw), Codable {")
            for (index, caseName) in names.compactMap(\.stringValue).enumerated() {
                if index < descriptions.count { lines += documented(descriptions[index], indent: "    ") }
                let value = index < values.count ? values[index] : .null
                let explicit: String? =
                    switch value {
                    case .string(let text) where text != caseName: " = \"\(text)\""
                    case .integer(let number): " = \(number)"
                    default: nil
                    }
                lines.append("    case \(caseName)\(explicit ?? "")")
            }
            lines.append("}")
            return lines.joined(separator: "\n")
        }
        // A structure: its fields, in the order they're declared.
        guard schema["properties"] != nil else { return nil }
        lines.append("struct \(name): Codable {")
        for (field, fieldSchema) in ordered(schema) {
            guard let type = fieldSchema.declaredType(optional: !required(schema).contains(field)) else { return nil }
            lines += documented(fieldSchema["description"], indent: "    ")
            lines.append("    var \(field): \(type)" + Self.swiftDefault(of: fieldSchema, required: true))
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// An object schema's fields, in the order they're declared when it says, and by name
    /// otherwise.
    private static func ordered(_ schema: JSONValue) -> [(String, JSONValue)] {
        let properties = schema["properties"]?.objectValue ?? [:]
        let order = schema["x-order"]?.arrayValue?.compactMap(\.stringValue) ?? properties.keys.sorted()
        return order.compactMap { name in properties[name].map { (name, $0) } }
    }

    private static func required(_ schema: JSONValue) -> Set<String> {
        Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    /// What each parameter is, as Swift documents a function's: `- Parameter name: …` for one,
    /// a `- Parameters:` list for more, in the order they're declared.
    static func documentedParameters(of schema: JSONValue?, indent: String) -> [String] {
        let properties = schema?["properties"]?.objectValue ?? [:]
        let said: [(String, String)] = (parameters(of: schema) ?? []).compactMap { parameter in
            guard case .string(let text)? = properties[parameter.name]?["description"], !text.isEmpty else {
                return nil
            }
            return (parameter.name, text)
        }
        guard said.count > 1 else { return said.map { "\(indent)/// - Parameter \($0.0): \($0.1)" } }
        return ["\(indent)/// - Parameters:"] + said.map { "\(indent)///   - \($0.0): \($0.1)" }
    }

    static func documented(_ description: JSONValue?, indent: String) -> [String] {
        guard case .string(let text)? = description, !text.isEmpty else { return [] }
        return ["\(indent)/// \(text)"]
    }
}

extension JSONValue {
    /// The schemas inside this one: its fields', its elements', and its choices'.
    var children: [JSONValue] {
        var children: [JSONValue] = []
        if case .object(let properties)? = self["properties"] { children += properties.values }
        if let items = self["items"] { children.append(items) }
        if case .object = self["additionalProperties"], let values = self["additionalProperties"] {
            children.append(values)
        }
        if case .array(let options)? = self["anyOf"] { children += options }
        if case .array(let options)? = self["oneOf"] { children += options }
        return children
    }

    /// The name of the type this schema describes, when it's a type's: its `title`.
    var typeName: String? {
        if case .string(let name)? = self[Discovery.swiftTypeKey], !name.isEmpty { name } else { nil }
    }

    /// The Swift type of a value of this schema, an optional when it's `optional` and isn't
    /// already one.
    public func declaredType(optional: Bool) -> String? {
        guard let type = swiftType else { return nil }
        return optional && !type.hasSuffix("?") ? type + "?" : type
    }
}
