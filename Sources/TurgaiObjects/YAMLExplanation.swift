import Yams

/// A YAML mistake explained the way Elm explains a compile error: where it is, what YAML read
/// there and why, and how to fix it, with the fixed line when it can be worked out.
public enum YAMLExplanation {
    public static func explain(_ error: any Error) -> String {
        switch error as? YamlError {
        case .scanner(let context, let problem, let mark, let yaml),
            .parser(let context, let problem, let mark, let yaml),
            .composer(let context, let problem, let mark, let yaml):
            return explain(problem: problem, at: mark, opened: context?.mark, in: yaml)
        case .duplicatedKeysInMapping(let duplicates, _):
            let keys = duplicates.sorted().map { "`\($0)`" }.joined(separator: ", ")
            return "The key \(keys) appears twice in the same mapping. Give each key once."
        default:
            return "I couldn't read the arguments as YAML: \(error)"
        }
    }

    private static func explain(problem: String, at mark: Mark, opened: Mark?, in yaml: String) -> String {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let line = lines.indices.contains(mark.line - 1) ? lines[mark.line - 1] : ""
        let shown = "I couldn't read line \(mark.line) of the arguments:\n\n" + snippet(line, number: mark.line, column: mark.column)

        if problem.contains("mapping values are not allowed") {
            let advice = "This value has a second \": \" in it. YAML reads \": \" as the start of a key, so text that contains one has to be in quotes"
            guard let quoted = quotingValue(of: line) else { return "\(shown)\n\n\(advice)." }
            return "\(shown)\n\n\(advice):\n\n    \(quoted)"
        }
        if problem.contains("tab character") || (problem.contains("cannot start any token") && line.hasPrefix("\t")) {
            return "\(shown)\n\nThis line is indented with a tab. YAML only allows spaces for indentation."
        }
        if problem.contains("cannot start any token") {
            return "\(shown)\n\nThis value starts with a character YAML keeps for itself, such as `@` or a backtick. Put the value in quotes."
        }
        if problem.contains("did not find expected key") || problem.contains("did not find expected '-' indicator") {
            return "\(shown)\n\nThis line isn't indented like the lines around it. In YAML, the keys of one mapping, and the items of one list, all start in the same column."
        }
        if problem.contains("could not find expected ':'") {
            return "\(shown)\n\nThis line has a key without a \":\" after it. Write `key: value`, with a space after the colon."
        }
        if problem.contains("did not find expected ',' or '}'") || problem.contains("did not find expected ',' or ']'") {
            let start = opened.map { " opened on line \($0.line)" } ?? ""
            return "\(shown)\n\nThe bracket\(start) isn't closed where YAML expected. Check the brackets, or write it as indented lines instead, one key per line."
        }
        if problem.contains("expected <document start>") {
            return "\(shown)\n\nThe arguments end before this, so whatever is here is one too many: often an extra `}` or `]`. Remove it."
        }
        if problem.contains("end of stream"), let opened {
            return "\(shown)\n\nSomething opened on line \(opened.line), a quote or a bracket, is never closed."
        }
        return "\(shown)\n\nYAML says: \(problem)."
    }

    /// The line with a caret under the column, the way Elm shows where a mistake is.
    private static func snippet(_ line: String, number: Int, column: Int) -> String {
        let gutter = "\(number) | "
        return "    \(gutter)\(line)\n    " + String(repeating: " ", count: gutter.count + max(column - 1, 0)) + "^"
    }

    /// `line` with everything after its key in double quotes, such as
    /// `- startShift: "call the shop (from: self)"`.
    private static func quotingValue(of line: String) -> String? {
        guard let separator = line.range(of: ": ") else { return nil }
        let key = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let value = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.hasPrefix("\"") else { return nil }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\(key): \"\(escaped)\""
    }
}
