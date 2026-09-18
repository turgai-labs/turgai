import Markdown

/// Renders model and user Markdown into safe HTML for the web boundary.
public enum MarkdownRenderer {
    public static func html(from markdown: String) -> String {
        sanitize(HTMLFormatter.format(unescapeJSON(markdown)))
    }

    private static func unescapeJSON(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "\\\\", with: "\\")
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        result = result.replacingOccurrences(of: "\\r", with: "\r")
        result = result.replacingOccurrences(of: "\\t", with: "\t")
        result = result.replacingOccurrences(of: "\\\"", with: "\"")
        result = result.replacingOccurrences(of: "\\/", with: "/")
        return result
    }

    private static func sanitize(_ html: String) -> String {
        var result = html
        for tag in ["script", "style", "iframe", "object", "embed"] {
            result = result.replacingOccurrences(
                of: "<\(tag)[^>]*>.*?</\(tag)>",
                with: "",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: "<\(tag)[^>]*/?>",
                with: "",
                options: .regularExpression
            )
        }
        return result.replacingOccurrences(
            of: #"\bon\w+="[^"]*""#,
            with: "",
            options: .regularExpression
        )
    }
}
