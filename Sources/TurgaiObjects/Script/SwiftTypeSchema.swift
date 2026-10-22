import DiscoverableActors
import Doppel

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A Swift type as the JSON schema its values are described with: the schema `@Discoverable` gives
/// a compiled type, so the model and other objects meet a made object's types as they meet a
/// built-in object's. It's written from the type the checker resolved, never from the code's text.
enum SwiftTypeSchema {
    /// The schema of a value of `type`, whose named types `declarations` declares. An optional is
    /// its wrapped type's: whether it may be left out is said where it's used.
    static func schema(of type: SwiftType, in declarations: Declarations) -> JSONValue {
        var writing = Writing(declarations: declarations)
        return writing.schema(of: type)
    }

    /// `type` as code anywhere names it, a nested type with the types it's in; `nil` for any
    /// object, which is written as it's declared.
    static func written(_ type: SwiftType) -> String? {
        switch type {
        case .int, .double, .bool, .string, .character, .fixedInteger, .void, .never: type.description
        case .optional(let wrapped): written(wrapped).map { "\($0)?" }
        case .array(let element): written(element).map { "[\($0)]" }
        case .dictionary(let key, let value): written(key).flatMap { key in written(value).map { "[\(key): \($0)]" } }
        case .named(let name, let arguments):
            arguments.isEmpty ? name : Self.all(arguments.map(written)).map { "\(name)<\($0.joined(separator: ", "))>" }
        // An object conforming to a protocol, as code writes it: `any Shop.RefundManager`.
        case .existential(let protocols) where !isAnyObject(type): "any " + protocols.joined(separator: " & ")
        default: nil
        }
    }

    /// The protocol `type` conforms objects to, when it's an object conforming to one that
    /// `declarations` declares: `any Shop.RefundManager`.
    static func conformed(_ type: SwiftType, in declarations: Declarations) -> ObjectProtocolName? {
        guard case .existential(let protocols) = type.unwrapped, protocols.count == 1, let name = protocols.first,
            case .protocol? = declarations[name]
        else { return nil }
        return ObjectProtocolName(rawValue: name)
    }

    /// Every one of `values`, when none is `nil`.
    private static func all(_ values: [String?]) -> [String]? {
        let present = values.compactMap { $0 }
        return present.count == values.count ? present : nil
    }

    /// Whether `type` is any object, `Object` as the module declares it: `any Actor`.
    static func isAnyObject(_ type: SwiftType) -> Bool {
        if case .existential(let protocols) = type.unwrapped { protocols == ["Actor"] } else { false }
    }

    /// Whether a value of `type` may be left out: it's optional.
    static func isOptional(_ type: SwiftType) -> Bool {
        if case .optional = type { true } else { false }
    }

    private struct Writing {
        let declarations: Declarations
        /// The named types being written, so a type that holds itself is named, not written again.
        var writing: Set<String> = []

        mutating func schema(of type: SwiftType) -> JSONValue {
            switch type {
            case .int, .fixedInteger: return ["type": "integer"]
            case .double: return ["type": "number"]
            case .bool: return ["type": "boolean"]
            case .string, .character: return ["type": "string"]
            case .optional(let wrapped), .inout(let wrapped): return schema(of: wrapped)
            case .array(let element): return ["type": "array", "items": schema(of: element)]
            case .dictionary(.string, let value): return ["type": "object", "additionalProperties": schema(of: value)]
            // As `Codable` writes them: keyed by `Int`, an object whose keys are the digits; keyed
            // by anything else, its keys and values in turn.
            case .dictionary(.int, let value):
                return [
                    "type": "object", "propertyNames": ["pattern": "^-?[0-9]+$"],
                    "additionalProperties": schema(of: value),
                ]
            case .dictionary(let key, let value):
                return ["type": "array", "items": ["anyOf": [schema(of: key), schema(of: value)]]]
            case .named(let name, _): return named(name)
            // An object conforming to a protocol goes as a reference to it, as any object does.
            case .existential(let protocols)
            where protocols.count == 1 && declarations[protocols[0]].map(Self.isProtocol) == true:
                guard case .object(var reference) = Discovery.actorReferenceSchema else { return [:] }
                if case .protocol(_, let documentation?)? = declarations[protocols[0]] {
                    reference["description"] = .string(documentation)
                }
                reference[Discovery.swiftTypeKey] = .string("any \(protocols[0])")
                return .object(reference)
            default: return [:]
            }
        }

        private static func isProtocol(_ declaration: Declarations.Declaration) -> Bool {
            if case .protocol = declaration { true } else { false }
        }

        private mutating func named(_ name: String) -> JSONValue {
            // Foundation's, as every object describes them: a date as text with its format.
            switch name {
            case "Date": return Date.jsonSchema
            case "Decimal": return Decimal.jsonSchema
            case "UUID": return UUID.jsonSchema
            case "URL": return URL.jsonSchema
            default: break
            }
            guard let declaration = declarations[name], !writing.contains(name) else {
                return .object([Discovery.swiftTypeKey: .string(name)])
            }
            writing.insert(name)
            defer { writing.remove(name) }
            var object: [String: JSONValue]
            switch declaration {
            case .actor(_, _, _, let documentation):
                guard case .object(let reference) = Discovery.actorReferenceSchema else { return [:] }
                object = reference
                if let documentation { object["description"] = .string(documentation) }
            case .structure(let fields, _, let documentation):
                object = Self.object(
                    fields.map { field in
                        (
                            field.name, described(schema(of: field.type), field.documentation),
                            SwiftTypeSchema.isOptional(field.type) || field.hasDefault
                        )
                    }, documentation: documentation)
            case .enumeration(let cases, _, let documentation):
                object = enumeration(cases)
                if let documentation { object["description"] = .string(documentation) }
            case .protocol:
                // A protocol names no value: an object conforming to it is `any` of it.
                return [:]
            }
            object[Discovery.swiftTypeKey] = .string(name)
            return .object(object)
        }

        /// An enum's cases as `Codable` writes them: its raw values, or one key per case holding
        /// its values.
        private mutating func enumeration(_ cases: [Declarations.Case]) -> [String: JSONValue] {
            if cases.allSatisfy(\.values.isEmpty) {
                let values: [JSONValue] = cases.map { enumCase in
                    switch enumCase.rawValue {
                    case .int(let number)?: .integer(Int64(number))
                    case .double(let number)?: .number(number)
                    case .string(let text)?: .string(text)
                    case nil: .string(enumCase.name)
                    }
                }
                let kind: JSONValue =
                    switch values.first {
                    case .integer?: "integer"
                    case .number?: "number"
                    default: "string"
                    }
                return [
                    "type": kind, "enum": .array(values), "x-enum-varnames": .array(cases.map { .string($0.name) }),
                ]
            }
            let options: [JSONValue] = cases.map { enumCase in
                let values = enumCase.values.enumerated().map { index, value in
                    (
                        value.label ?? "_\(index)", schema(of: value.type),
                        SwiftTypeSchema.isOptional(value.type) || value.hasDefault
                    )
                }
                return [
                    "type": "object",
                    "properties": [enumCase.name: .object(Self.object(values, documentation: enumCase.documentation))],
                    "required": [.string(enumCase.name)],
                    "additionalProperties": false,
                ]
            }
            return ["oneOf": .array(options)]
        }

        private func described(_ schema: JSONValue, _ documentation: String?) -> JSONValue {
            guard let documentation, case .object(var object) = schema else { return schema }
            object["description"] = .string(documentation)
            return .object(object)
        }

        /// An object of `fields`, in their order, those that may be left out not required.
        private static func object(
            _ fields: [(name: String, schema: JSONValue, optional: Bool)], documentation: String?
        ) -> [String: JSONValue] {
            var object: [String: JSONValue] = [
                "type": "object",
                "properties": .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.schema) })),
                "required": .array(fields.filter { !$0.optional }.map { .string($0.name) }),
                "x-order": .array(fields.map { .string($0.name) }),
            ]
            if let documentation { object["description"] = .string(documentation) }
            return object
        }
    }
}
