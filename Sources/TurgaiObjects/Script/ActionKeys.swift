/// An action's key, as its object describes it: a name, `plan`, or one of an overloaded name's
/// selectors, `plan(request:)` or `plan(_: String)`.
public enum ActionKeys {
    /// The name it's called by in Swift: `plan` for `plan(request:)`.
    public static func baseName(of key: String) -> String {
        key.firstIndex(of: "(").map { String(key[..<$0]) } ?? key
    }

    /// It as a tool's name, which providers take only of letters, digits, `_` and `-`:
    /// `plan_request` for `plan(request:)`, `plan` for `plan(_:)`, `plan_String` for `plan(_: String)`.
    public static func toolName(of key: String) -> String {
        guard key.contains("(") else { return key }
        var written = ""
        for character in key.replacingOccurrences(of: "_:", with: ":") {
            if character.isLetter || character.isNumber {
                written.append(character)
            } else if written.last != "_" {
                written.append("_")
            }
        }
        while written.last == "_" { written.removeLast() }
        return written
    }
}
