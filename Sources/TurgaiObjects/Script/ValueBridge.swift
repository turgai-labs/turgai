import DiscoverableActors
import SwiftScriptInterpreter
import SwiftSyntax

/// Values crossing between an object's code and other objects, as `Codable` writes them: a
/// struct as an object of its fields, without the optional ones that are `nil`; an enum with raw
/// values as its raw value; one with associated values as an object keyed by its case, holding
/// them by label, or `_0`, `_1` for unlabeled ones. What a type is, is read from the interpreter:
/// the types the code declares, and those it uses, as they're declared.
struct ValueBridge {
    let interpreter: Interpreter

    /// Why a value couldn't be read as its type, as `Codable` would refuse it.
    struct Mismatch: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Reading

    /// `json` as a value of `type`.
    func value(of json: JSONValue, as type: TypeSyntax) throws(Mismatch) -> Value {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return json == .null ? .optional(nil) : .optional(try value(of: json, as: optional.wrappedType))
        }
        if let array = type.as(ArrayTypeSyntax.self) {
            guard case .array(let items) = json else { throw Mismatch(description: "expected an array for `\(type.trimmedDescription)`, got \(json.inline)") }
            var values: [Value] = []
            for item in items { values.append(try value(of: item, as: array.element)) }
            return .array(values)
        }
        if let dictionary = type.as(DictionaryTypeSyntax.self) {
            guard case .object(let members) = json else { throw Mismatch(description: "expected an object for `\(type.trimmedDescription)`, got \(json.inline)") }
            var entries: [DictEntry] = []
            for (key, member) in members.sorted(by: { $0.key < $1.key }) {
                entries.append(DictEntry(key: .string(key), value: try value(of: member, as: dictionary.value)))
            }
            return .dict(entries)
        }
        let name = type.trimmedDescription
        if let declared = interpreter.declaredStruct(name) { return try structure(json, declared) }
        if let declared = interpreter.declaredEnum(name) { return try enumeration(json, declared) }
        // Another object, as the actor the code imports declares it.
        if interpreter.importedActor(name) != nil, let reference = ObjectReference(json) { return .opaque(typeName: name, value: reference) }
        // Data, an object, or a type nothing declares: as it reads.
        return typed(ScriptInstance.value(of: json, as: ValueKind(type, declared: [])))
    }

    private func structure(_ json: JSONValue, _ declared: StructDef) throws(Mismatch) -> Value {
        guard case .object(let members) = json else { throw Mismatch(description: "expected an object for `\(declared.name)`, got \(json.inline)") }
        var fields: [StructField] = []
        for property in declared.properties {
            let member = members[property.name] ?? .null
            guard let type = property.type else {
                fields.append(StructField(name: property.name, value: ScriptInstance.value(of: member)))
                continue
            }
            // A missing value is `nil` for an optional, and a missing field otherwise.
            if member == .null, type.as(OptionalTypeSyntax.self) == nil {
                throw Mismatch(description: "`\(declared.name)` needs `\(property.name)`")
            }
            fields.append(StructField(name: property.name, value: try value(of: member, as: type)))
        }
        return .structValue(typeName: declared.name, fields: fields)
    }

    private func enumeration(_ json: JSONValue, _ declared: EnumDef) throws(Mismatch) -> Value {
        if declared.rawType != nil {
            let raw = ScriptInstance.value(of: json)
            guard let match = declared.cases.first(where: { $0.rawValue == raw }) else {
                throw Mismatch(description: "`\(json.inline)` is no case of `\(declared.name)`")
            }
            return .enumValue(typeName: declared.name, caseName: match.name, associatedValues: [])
        }
        guard case .object(let members) = json, members.count == 1, let (name, payload) = members.first,
            let match = declared.cases.first(where: { $0.name == name })
        else {
            throw Mismatch(description: "`\(json.inline)` is no case of `\(declared.name)`")
        }
        let given = payload.objectValue ?? [:]
        var values: [Value] = []
        for (index, parameter) in match.associated.enumerated() {
            let member = given[parameter.label ?? "_\(index)"] ?? .null
            values.append(try parameter.type.map { type throws(Mismatch) in try value(of: member, as: type) } ?? ScriptInstance.value(of: member))
        }
        return .enumValue(typeName: declared.name, caseName: match.name, associatedValues: values)
    }

    /// `value` with each object in it as its type, when its reference says one the code imports:
    /// what a journaled object reads back as.
    func typed(_ value: Value) -> Value {
        switch value {
        case .opaque("Object", let reference as ObjectReference):
            guard case .virtual(_, let type) = reference, interpreter.importedActor(type) != nil else { return value }
            return .opaque(typeName: type, value: reference)
        case .optional(.some(let wrapped)): return .optional(typed(wrapped))
        case .array(let items): return .array(items.map(typed))
        default: return value
        }
    }

    // MARK: Writing

    /// `value` as `Codable` writes it; a value that isn't data can't be written.
    func json(of value: Value) throws(CodeProblem) -> JSONValue {
        switch value {
        case .optional(.none): return .null
        case .optional(.some(let wrapped)): return try json(of: wrapped)
        case .array(let items), .set(let items):
            var written: [JSONValue] = []
            for item in items { written.append(try json(of: item)) }
            return .array(written)
        case .dict(let entries):
            var members: [String: JSONValue] = [:]
            for entry in entries {
                guard case .string(let key) = entry.key else { throw ScriptInstance.notData(value, "A dictionary not keyed by text") }
                members[key] = try json(of: entry.value)
            }
            return .object(members)
        case .structValue(_, let fields):
            var members: [String: JSONValue] = [:]
            for field in fields {
                if case .optional(.none) = field.value { continue }
                members[field.name] = try json(of: field.value)
            }
            return .object(members)
        case .enumValue(let type, let caseName, let values):
            guard let declared = interpreter.declaredEnum(type), let match = declared.cases.first(where: { $0.name == caseName }) else {
                throw ScriptInstance.notData(value, "`\(type).\(caseName)`")
            }
            if let raw = match.rawValue { return try json(of: raw) }
            var members: [String: JSONValue] = [:]
            for (index, associated) in values.enumerated() {
                let label = index < match.associated.count ? match.associated[index].label : nil
                members[label ?? "_\(index)"] = try json(of: associated)
            }
            return [caseName: .object(members)]
        default:
            // Plain data and objects read the same in both.
            return try ScriptInstance.json(value, "A value")
        }
    }
}
