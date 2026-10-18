import DiscoverableActors
import Foundation
import SwiftParser
import SwiftSyntax

/// What an object's code was written against: the other objects around it and the values they
/// send and take, as the module its code imports, and the names objects are reached by. It's kept
/// with the code, so the code runs as it was checked. Calls stay messages, by name, to whichever
/// object is there: this is what the code expects, never a link.
public struct Uses: Codable, Sendable, Equatable {
    /// The objects and their values, as the module the code imports declares them.
    public let interface: ModuleInterface
    /// The objects code reaches by name, each name's type.
    public let names: [String: String]

    public init(interface: ModuleInterface, names: [String: String]) {
        self.interface = interface
        self.names = names
    }

    /// Nothing from other objects.
    public static let nothing = Uses(interface: ModuleInterface(name: Uses.module, source: ""), names: [:])

    /// The module objects' code imports.
    public static let module = "Objects"
}

// MARK: The spec, as Swift declares it

extension Uses {
    /// An object, as the spec renders it: the type code reaches it as, what it is, and whether
    /// what it publishes can be read, as another kind of object's can.
    public struct Object: Sendable {
        public let type: String
        public let description: ObjectDescription
        public let publishes: Bool

        public init(type: String, description: ObjectDescription, publishes: Bool) {
            self.type = type
            self.description = description
            self.publishes = publishes
        }
    }

    /// The module `objects` make, as Swift declares it: each object an actor, with its methods,
    /// what it publishes and its events, and the structs and enums their values are.
    public static func interface(of objects: [Object]) -> ModuleInterface {
        var schemas: [JSONValue] = []
        var actors: [String] = []
        for object in objects {
            var lines = documented(object.description.description.map(JSONValue.string), indent: "")
            lines.append("actor \(object.type) {")
            if object.publishes {
                for (name, property) in object.description.properties.sorted(by: { $0.key < $1.key }) {
                    lines += documented(property["description"], indent: "    ")
                    // Read from another actor's node: awaited, and tried, whatever it holds.
                    lines.append("    var \(name): \(property.swiftType) { get async throws }")
                    schemas.append(property)
                }
            }
            for (name, action) in object.description.actions.sorted(by: { $0.key < $1.key }) {
                lines += documented(action.description.map(JSONValue.string), indent: "    ")
                lines += documentedParameters(of: action.input, indent: "    ")
                // Called on another actor's node: awaited, and tried, whatever its code declares.
                lines.append(
                    "    func \(name)(\(written(parameters(of: action.input)))) async throws" + (action.output.map { " -> \($0.swiftType)" } ?? ""))
                if let input = action.input { schemas.append(input) }
                if let output = action.output { schemas.append(output) }
            }
            for (name, event) in object.description.events.sorted(by: { $0.key < $1.key }) {
                // As a function, named as Swift names one: `TrackChanged`'s is `trackChanged`.
                let function = name.prefix(1).lowercased() + name.dropFirst()
                lines.append("    @\(RuntimeMacros.event) func \(function)(\(written(parameters(of: event.data))))")
                // Its handler takes its values, never the event itself: the types are its values'.
                if case .object(let values)? = event.data["properties"] { schemas += values.values }
            }
            lines.append("}")
            actors.append(lines.joined(separator: "\n"))
        }
        let values = declarations(of: schemas)
        return ModuleInterface(name: module, source: (actors + (values.isEmpty ? [] : [values])).joined(separator: "\n\n"))
    }

    /// The parameters a schema's values are, as Swift declares them, in the order they're
    /// declared: each with its label, `nil` for `_`, its name and its type, an optional where
    /// it may be left out.
    public static func parameters(of schema: JSONValue?) -> [(label: String?, name: String, type: String)] {
        guard case .object(let properties)? = schema?["properties"] else { return [] }
        let required = Set(schema?["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let order = schema?["x-order"]?.arrayValue?.compactMap(\.stringValue)
            ?? properties.keys.filter(required.contains).sorted() + properties.keys.filter { !required.contains($0) }.sorted()
        return order.compactMap { name in
            guard let property = properties[name] else { return nil }
            // Its label as its code declares it, `_` for none; an object that doesn't say is
            // called with its parameters' names.
            let label: String? =
                switch property[ObjectShape.Message.labelKey] {
                case .string("_")?: nil
                case .string(let label)?: label
                default: name
                }
            return (label, name, property.declaredType(optional: !required.contains(name)))
        }
    }

    /// Parameters as a declaration lists them: `from ann: Ann, _ amount: Int`.
    static func written(_ parameters: [(label: String?, name: String, type: String)]) -> String {
        parameters.map { parameter in
            (parameter.label == parameter.name ? parameter.name : "\(parameter.label ?? "_") \(parameter.name)") + ": \(parameter.type)"
        }.joined(separator: ", ")
    }
}

// MARK: The values, in words

extension Uses {
    /// The structs and enums the code imports, each in a few lines, as the writer is told them:
    /// what it is, then its fields or its cases, each with its type as Swift writes it. Words,
    /// never declarations to copy.
    public var valuesInWords: [String] {
        Parser.parse(source: interface.source).statements.compactMap { statement -> String? in
            if let structure = statement.item.as(StructDeclSyntax.self) {
                var lines = [Self.titled(structure.name.text, Self.summary(structure.leadingTrivia)), "  Fields:"]
                for member in structure.memberBlock.members {
                    guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
                    for binding in variable.bindings {
                        let type = binding.typeAnnotation?.type.trimmedDescription ?? "Any"
                        lines.append("    \(binding.pattern.trimmedDescription): \(type)" + Self.said(Self.summary(variable.leadingTrivia)))
                    }
                }
                return lines.joined(separator: "\n")
            }
            if let enumeration = statement.item.as(EnumDeclSyntax.self) {
                var lines = [Self.titled(enumeration.name.text, Self.summary(enumeration.leadingTrivia)) + " One of:"]
                for member in enumeration.memberBlock.members {
                    guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
                    for element in cases.elements {
                        let values = element.parameterClause.map { clause in
                            "(" + clause.parameters.map { parameter in
                                (parameter.firstName.map { "\($0.text): " } ?? "") + parameter.type.trimmedDescription
                            }.joined(separator: ", ") + ")"
                        } ?? ""
                        lines.append("    \(element.name.text)\(values)" + Self.said(Self.summary(cases.leadingTrivia)))
                    }
                }
                return lines.joined(separator: "\n")
            }
            return nil
        }
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
            if case .docLineComment(let text) = piece { String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) } else { nil }
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

    static func declarations(of schemas: [JSONValue]) -> String {
        var named: [(name: String, schema: JSONValue)] = []
        func collect(_ schema: JSONValue) {
            if let name = schema.typeName, !named.contains(where: { $0.name == name }) {
                named.append((name, schema))
            }
            for child in schema.children { collect(child) }
        }
        for schema in schemas { collect(schema) }
        return named.compactMap { declaration(of: $0.schema, named: $0.name) }.joined(separator: "\n\n")
    }

    /// One type's declaration, read from its schema.
    static func declaration(of schema: JSONValue, named name: String) -> String? {
        var lines = documented(schema["description"], indent: "")
        // An enumeration with associated values: one option per case, as `Codable` writes it.
        if case .array(let options)? = schema["oneOf"], options.allSatisfy({ $0["properties"]?.objectValue?.count == 1 && $0["const"] == nil }) {
            lines.append("enum \(name) {")
            for option in options {
                guard let (caseName, values) = option["properties"]?.objectValue?.first else { continue }
                lines += documented(values["description"], indent: "    ")
                let associated = ordered(values).map { label, field in
                    (label.hasPrefix("_") ? "" : "\(label): ") + field.declaredType(optional: !required(values).contains(label))
                        + Self.swiftDefault(of: field, required: required(values).contains(label))
                }
                lines.append("    case \(caseName)" + (associated.isEmpty ? "" : "(\(associated.joined(separator: ", ")))"))
            }
            lines.append("}")
            return lines.joined(separator: "\n")
        }
        // An enumeration with raw values, its cases as Swift names them.
        if case .array(let names)? = schema["x-enum-varnames"] {
            let values: [JSONValue] = if case .array(let values)? = schema["enum"] { values } else { (schema["oneOf"]?.arrayValue ?? []).map { $0["const"] ?? .null } }
            let descriptions = (schema["oneOf"]?.arrayValue ?? []).map(\.["description"])
            let raw = schema["type"] == "integer" ? "Int" : "String"
            lines.append("enum \(name): \(raw) {")
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
        lines.append("struct \(name) {")
        for (field, fieldSchema) in ordered(schema) {
            lines += documented(fieldSchema["description"], indent: "    ")
            lines.append(
                "    var \(field): \(fieldSchema.declaredType(optional: !required(schema).contains(field)))"
                    + Self.swiftDefault(of: fieldSchema, required: true))
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
        let said: [(String, String)] = parameters(of: schema).compactMap { parameter in
            guard case .string(let text)? = properties[parameter.name]?["description"], !text.isEmpty else { return nil }
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
        if case .object = self["additionalProperties"], let values = self["additionalProperties"] { children.append(values) }
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
    public func declaredType(optional: Bool) -> String {
        let type = swiftType
        return optional && !type.hasSuffix("?") ? type + "?" : type
    }
}
