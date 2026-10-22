import DiscoverableActors
import Foundation

extension JSONValue {
    /// The value on one line, as YAML's flow style writes it: `[1, 2]`, `{number: 2}`, `text`.
    public var inline: String {
        switch self {
        case .null: "null"
        case .bool(let bool): "\(bool)"
        case .integer(let integer): "\(integer)"
        case .unsignedInteger(let integer): "\(integer)"
        case .number(let number): number.rounded() == number && abs(number) < 1e15 ? "\(Int64(number))" : "\(number)"
        case .string(let text): text
        case .array(let items): "[\(items.map(\.inline).joined(separator: ", "))]"
        case .object(let members):
            "{\(members.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.inline)" }.joined(separator: ", "))}"
        }
    }

    var string: String? {
        if case .string(let text) = self { text } else { nil }
    }
}

extension JSONValue {
    /// The Swift type a value of this schema is, as code writes it: as its code wrote it, when it
    /// says, and otherwise an object is an `Object`; `nil` when the schema doesn't say a type.
    public var swiftType: String? {
        if case .string(let type)? = self[ObjectShape.Message.swiftTypeKey] { return type }
        if let name = typeName { return name }
        if self["x-actor-reference"] == .bool(true) || self["x-takes"] != nil { return "Object" }
        // A value or nothing: `T?`.
        if case .array(let options)? = self["anyOf"], options.count == 2,
            let null = options.firstIndex(of: ["type": "null"])
        {
            return options[1 - null].declaredType(optional: true)
        }
        switch self["type"] {
        case "string": return "String"
        case "integer": return "Int"
        case "number": return "Double"
        case "boolean": return "Bool"
        case "array": return self["items"]?.swiftType.map { "[\($0)]" }
        default:
            if let values = self["additionalProperties"], case .object = values {
                return values.swiftType.map { "[String: \($0)]" }
            }
            return nil
        }
    }
}
