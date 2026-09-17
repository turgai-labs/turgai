#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Markdown-to-Telegram-HTML formatting belongs at the Telegram boundary.
/// The domain continues to deal in ordinary text and never has to know about
/// Telegram tags or escaping rules.
public enum TelegramHTMLFormatter {
    public static func render(markdown: String) -> String {
        render(tokens: tokens(for: document(markdown: markdown)))
    }

    /// Renders Markdown and splits the result by visible characters without
    /// breaking formatting tags, entities, or code blocks.
    public static func chunks(
        markdown: String,
        maximumLength: Int
    ) -> [String] {
        chunk(
            tokens: tokens(for: document(markdown: markdown)),
            maximumLength: maximumLength
        )
    }

    /// Returns one independently valid HTML fragment for a streaming draft.
    public static func firstChunk(
        markdown: String,
        maximumLength: Int
    ) -> String {
        chunks(markdown: markdown, maximumLength: maximumLength).first ?? ""
    }

    /// Returns the first draft chunk without publishing Markdown that can
    /// still change when more model output arrives.
    ///
    /// A draft update must keep its already visible prefix stable. For
    /// example, publishing `**hello` as literal text and then replacing it
    /// with `<b>hello</b>` makes Telegram restart the streamed preview. The
    /// unfinished construct is therefore held back until it is complete.
    public static func streamingFirstChunk(
        markdown: String,
        maximumLength: Int
    ) -> String {
        firstChunk(
            markdown: stablePrefix(markdown: markdown),
            maximumLength: maximumLength
        )
    }
}

private struct MarkdownDocument {
    let blocks: [MarkdownBlock]
}

private enum MarkdownBlock {
    case paragraph([MarkdownInline])
    case heading([MarkdownInline])
    case unorderedItem([MarkdownInline])
    case orderedItem(number: String, content: [MarkdownInline])
    case blockquote([[MarkdownInline]])
    case table(headers: [String], rows: [[String]])
    case code(language: String?, text: String)
    case horizontalRule
    case blank
}

private indirect enum MarkdownInline {
    case text(String)
    case bold([MarkdownInline])
    case italic([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(label: [MarkdownInline], destination: String)
}

private struct InlineParseResult {
    let nodes: [MarkdownInline]
    let end: Int
    let closed: Bool
}

private struct MarkdownStyle {
    let delimiter: String
    let tag: String
}

private enum TableBoundary {
    case complete(end: Int)
    case incomplete
    case notTable
}

private struct HTMLTag {
    let raw: String
    let name: String

    var closing: String { "</\(name)>" }
}

private enum HTMLToken {
    case text(String)
    case open(HTMLTag)
    case close(HTMLTag)
}

extension TelegramHTMLFormatter {
    fileprivate static let styles = [
        MarkdownStyle(delimiter: "**", tag: "b"),
        MarkdownStyle(delimiter: "__", tag: "b"),
        MarkdownStyle(delimiter: "~~", tag: "s"),
        MarkdownStyle(delimiter: "*", tag: "i"),
        MarkdownStyle(delimiter: "_", tag: "i"),
    ]

    fileprivate static func document(markdown: String) -> MarkdownDocument {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines =
            normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if let fence = fenceStart(in: line) {
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    if fenceEnd(in: lines[index], marker: fence.marker) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(
                    .code(
                        language: fence.language.isEmpty ? nil : fence.language,
                        text: codeLines.joined(separator: "\n")
                    )
                )
                continue
            }

            if let table = table(in: lines, startingAt: index) {
                blocks.append(table.block)
                index = table.nextIndex
                continue
            }

            if let quote = blockquoteContent(in: line) {
                var quoteLines = [quote]
                index += 1
                while index < lines.count,
                    let continuation = blockquoteContent(in: lines[index])
                {
                    quoteLines.append(continuation)
                    index += 1
                }
                blocks.append(.blockquote(quoteLines.map(inlineNodes)))
                continue
            }

            blocks.append(block(for: line))
            index += 1
        }

        return MarkdownDocument(blocks: blocks)
    }

    fileprivate static func table(
        in lines: [String],
        startingAt index: Int
    ) -> (block: MarkdownBlock, nextIndex: Int)? {
        guard index + 1 < lines.count,
            let headers = tableCells(in: lines[index]),
            headers.count >= 2,
            let separator = tableCells(in: lines[index + 1]),
            isTableSeparatorRow(separator)
        else {
            return nil
        }

        var rows: [[String]] = []
        var nextIndex = index + 2
        while nextIndex < lines.count,
            let row = tableCells(in: lines[nextIndex])
        {
            rows.append(row)
            nextIndex += 1
        }

        return (
            .table(headers: headers, rows: rows),
            nextIndex
        )
    }

    fileprivate static func tableBoundary(
        in characters: [Character],
        startingAt start: Int
    ) -> TableBoundary {
        guard start < characters.count else { return .notTable }

        let headerEnd =
            characters[start...].firstIndex(of: "\n")
            ?? characters.count
        let header = String(characters[start..<headerEnd])
        guard let headers = tableCells(in: header), headers.count >= 2 else {
            return .notTable
        }

        guard headerEnd < characters.count else {
            return .incomplete
        }

        let separatorStart = headerEnd + 1
        guard separatorStart < characters.count else {
            return .incomplete
        }
        let separatorEnd =
            characters[separatorStart...].firstIndex(of: "\n")
            ?? characters.count
        let separator = String(characters[separatorStart..<separatorEnd])

        guard let separatorCells = tableCells(in: separator) else {
            return separatorEnd == characters.count
                && isPossibleTableSeparator(separator)
                ? .incomplete
                : .notTable
        }

        guard isTableSeparatorRow(separatorCells) else {
            return separatorEnd == characters.count
                && isPossibleTableSeparator(separator)
                ? .incomplete
                : .notTable
        }

        var nextStart =
            separatorEnd < characters.count
            ? separatorEnd + 1
            : separatorEnd
        while nextStart < characters.count {
            let lineEnd =
                characters[nextStart...].firstIndex(of: "\n")
                ?? characters.count
            let line = String(characters[nextStart..<lineEnd])
            guard tableCells(in: line) != nil else {
                return .complete(end: nextStart)
            }
            nextStart = lineEnd < characters.count ? lineEnd + 1 : lineEnd
        }
        return .complete(end: characters.count)
    }

    fileprivate static func tableCells(in line: String) -> [String]? {
        let characters = Array(line)
        var cells: [String] = []
        var cell = ""
        var hasPipe = false
        var index = 0

        while index < characters.count {
            if characters[index] == "\\",
                index + 1 < characters.count,
                characters[index + 1] == "|"
            {
                cell.append("|")
                index += 2
                continue
            }
            if characters[index] == "|" {
                hasPipe = true
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell.removeAll(keepingCapacity: true)
            } else {
                cell.append(characters[index])
            }
            index += 1
        }

        guard hasPipe else { return nil }
        cells.append(cell.trimmingCharacters(in: .whitespaces))

        if characters.first == "|", !cells.isEmpty {
            cells.removeFirst()
        }
        if characters.last == "|", !cells.isEmpty {
            cells.removeLast()
        }
        return cells
    }

    fileprivate static func isTableSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty
            && cells.allSatisfy { cell in
                var characters = Array(cell)
                if characters.first == ":" {
                    characters.removeFirst()
                }
                if characters.last == ":" {
                    characters.removeLast()
                }
                return characters.count >= 3
                    && characters.allSatisfy { $0 == "-" }
            }
    }

    fileprivate static func isPossibleTableSeparator(_ line: String) -> Bool {
        let characters = Array(line.filter { !$0.isWhitespace })
        return !characters.isEmpty
            && characters.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" }
    }

    fileprivate static func stablePrefix(markdown: String) -> String {
        let characters = Array(markdown)
        guard !characters.isEmpty else { return "" }

        var lineStart = 0
        while lineStart < characters.count {
            let lineEnd =
                characters[lineStart...].firstIndex(of: "\n")
                ?? characters.count
            let line = Array(characters[lineStart..<lineEnd])
            let hasFollowingNewline = lineEnd < characters.count

            if let fence = fenceStart(in: String(line)) {
                guard
                    let closingLineEnd = closingFenceEnd(
                        in: characters,
                        after: lineEnd + (hasFollowingNewline ? 1 : 0),
                        marker: fence.marker
                    )
                else {
                    return String(characters[..<lineStart])
                }

                lineStart = closingLineEnd
                continue
            }

            switch tableBoundary(in: characters, startingAt: lineStart) {
            case .complete(let end):
                guard end < characters.count else {
                    return String(characters[..<lineStart])
                }
                lineStart = end
                continue
            case .incomplete:
                return String(characters[..<lineStart])
            case .notTable:
                break
            }

            if blockquoteContent(in: String(line)) != nil {
                let blockEnd = blockquoteBlockEnd(
                    in: characters,
                    lineEnd: lineEnd,
                    hasFollowingNewline: hasFollowingNewline
                )
                guard blockEnd < characters.count else {
                    return String(characters[..<lineStart])
                }
            }

            if isGrowingBlock(in: line, hasFollowingNewline: hasFollowingNewline) {
                return String(characters[..<lineStart])
            }

            if let offset = firstUnfinishedInlineConstruct(in: line) {
                if headingContent(in: String(line)) != nil
                    || blockquoteContent(in: String(line)) != nil
                {
                    return String(characters[..<lineStart])
                }
                return String(characters[..<(lineStart + offset)])
            }

            guard hasFollowingNewline else { break }
            lineStart = lineEnd + 1
        }

        return markdown
    }

    fileprivate static func blockquoteBlockEnd(
        in characters: [Character],
        lineEnd: Int,
        hasFollowingNewline: Bool
    ) -> Int {
        guard hasFollowingNewline else { return characters.count }

        var nextLineStart = lineEnd + 1
        while nextLineStart < characters.count {
            let nextLineEnd =
                characters[nextLineStart...].firstIndex(of: "\n")
                ?? characters.count
            guard
                blockquoteContent(
                    in: String(characters[nextLineStart..<nextLineEnd])
                ) != nil
            else {
                return nextLineStart
            }
            guard nextLineEnd < characters.count else {
                return characters.count
            }
            nextLineStart = nextLineEnd + 1
        }
        return characters.count
    }

    fileprivate static func closingFenceEnd(
        in characters: [Character],
        after start: Int,
        marker: Character
    ) -> Int? {
        var lineStart = start
        while lineStart < characters.count {
            let lineEnd =
                characters[lineStart...].firstIndex(of: "\n")
                ?? characters.count
            if fenceEnd(
                in: String(characters[lineStart..<lineEnd]),
                marker: marker
            ) {
                return lineEnd < characters.count ? lineEnd + 1 : lineEnd
            }
            guard lineEnd < characters.count else { return nil }
            lineStart = lineEnd + 1
        }
        return nil
    }

    fileprivate static func isGrowingBlock(
        in line: [Character],
        hasFollowingNewline: Bool
    ) -> Bool {
        guard !line.isEmpty else { return false }

        var start = 0
        while start < line.count, line[start] == " ", start < 3 {
            start += 1
        }
        let content = Array(line[start...])
        guard !content.isEmpty else { return false }

        let first = content[0]
        if first == "#" {
            var count = 0
            while count < content.count, content[count] == "#", count < 6 {
                count += 1
            }
            if count == content.count || (count < content.count && content[count] == " ") {
                return !hasFollowingNewline
            }
        }

        if first == ">",
            content.count == 1 || content[1] == " "
        {
            return !hasFollowingNewline
        }

        if ["-", "*", "+"].contains(first) {
            if content.count == 1 {
                return true
            }
            if content[1] == " " && isHorizontalRule(String(content)) {
                return !hasFollowingNewline
            }
        }

        if first.isNumber {
            var index = 0
            while index < content.count, content[index].isNumber {
                index += 1
            }
            if index == content.count {
                return true
            }
            if content[index] == ".",
                index + 1 == content.count || content[index + 1] == " "
            {
                return !hasFollowingNewline
            }
        }

        if isHorizontalRule(String(content)) {
            return !hasFollowingNewline
        }

        return false
    }

    fileprivate static func firstUnfinishedInlineConstruct(in line: [Character]) -> Int? {
        var index = inlineContentStart(in: line)
        while index < line.count {
            if line[index] == "\\" {
                if index + 1 == line.count { return index }
                index += 2
                continue
            }

            if line[index] == "`" {
                let runEnd = sameCharacterRun(in: line, from: index, character: "`")
                let delimiter = String(line[index..<runEnd])
                guard
                    let end = closingDelimiter(
                        in: line,
                        from: runEnd,
                        delimiter: delimiter
                    )
                else {
                    return index
                }
                index = end + delimiter.count
                continue
            }

            if line[index] == "[",
                link(in: line, from: index) == nil
            {
                return index
            }

            var foundStyle = false
            for style in styles {
                let delimiter = Array(style.delimiter)
                guard line[index...].starts(with: delimiter) else { continue }

                let contentStart = index + delimiter.count
                guard contentStart < line.count else { return index }
                guard
                    let end = closingDelimiter(
                        in: line,
                        from: contentStart,
                        delimiter: style.delimiter
                    )
                else {
                    return index
                }

                if style.delimiter == "_",
                    index > 0,
                    line[index - 1].isLetterOrNumber,
                    line[contentStart].isLetterOrNumber
                {
                    continue
                }

                guard end > contentStart else { return index }
                index = end + delimiter.count
                foundStyle = true
                break
            }
            if foundStyle { continue }

            index += 1
        }
        return nil
    }

    fileprivate static func inlineContentStart(in line: [Character]) -> Int {
        var start = 0
        while start < line.count, line[start] == " ", start < 3 {
            start += 1
        }
        guard start < line.count else { return start }

        let content = Array(line[start...])
        if content.count >= 2,
            ["-", "*", "+"].contains(content[0]),
            content[1] == " "
        {
            return start + 2
        }

        var numberEnd = 0
        while numberEnd < content.count, content[numberEnd].isNumber {
            numberEnd += 1
        }
        if numberEnd > 0,
            numberEnd + 1 < content.count,
            content[numberEnd] == ".",
            content[numberEnd + 1] == " "
        {
            return start + numberEnd + 2
        }

        return start
    }

    fileprivate static func block(for line: String) -> MarkdownBlock {
        let characters = Array(line)
        var start = 0
        while start < characters.count, characters[start] == " ", start < 3 {
            start += 1
        }
        let remaining = String(characters.dropFirst(start))

        if let heading = headingContent(in: remaining) {
            return .heading(inlineNodes(heading))
        }
        if let content = unorderedListContent(in: remaining) {
            return .unorderedItem(inlineNodes(content))
        }
        if let ordered = orderedListContent(in: remaining) {
            return .orderedItem(number: ordered.number, content: inlineNodes(ordered.content))
        }
        if isHorizontalRule(remaining) {
            return .horizontalRule
        }
        if line.isEmpty {
            return .blank
        }
        return .paragraph(inlineNodes(line))
    }

    fileprivate static func inlineNodes(_ text: String) -> [MarkdownInline] {
        parseInline(Array(text), from: 0, until: nil).nodes
    }

    fileprivate static func parseInline(
        _ characters: [Character],
        from start: Int,
        until delimiter: String?
    ) -> InlineParseResult {
        var index = start
        var plainText = ""
        var nodes: [MarkdownInline] = []

        func flushPlainText() {
            guard !plainText.isEmpty else { return }
            nodes.append(.text(plainText))
            plainText.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            if let delimiter,
                characters[index...].starts(with: Array(delimiter))
            {
                flushPlainText()
                return InlineParseResult(
                    nodes: nodes,
                    end: index,
                    closed: true
                )
            }

            if characters[index] == "\\" {
                if index + 1 < characters.count {
                    plainText.append(characters[index + 1])
                    index += 2
                } else {
                    plainText.append("\\")
                    index += 1
                }
                continue
            }

            if characters[index] == "`" {
                let runEnd = sameCharacterRun(in: characters, from: index, character: "`")
                let codeDelimiter = String(characters[index..<runEnd])
                if let end = closingDelimiter(
                    in: characters,
                    from: runEnd,
                    delimiter: codeDelimiter
                ) {
                    flushPlainText()
                    nodes.append(.code(String(characters[runEnd..<end])))
                    index = end + codeDelimiter.count
                    continue
                }
            }

            if characters[index] == "[",
                let link = link(in: characters, from: index)
            {
                if let destination = allowedURL(link.destination) {
                    flushPlainText()
                    let label = inlineNodes(String(characters[(index + 1)..<link.labelEnd]))
                    nodes.append(.link(label: label, destination: destination))
                    index = link.end + 1
                    continue
                }
            }

            var parsedStyle = false
            for style in styles {
                let styleCharacters = Array(style.delimiter)
                guard characters[index...].starts(with: styleCharacters) else {
                    continue
                }

                let contentStart = index + styleCharacters.count
                guard contentStart < characters.count else { continue }
                let nested = parseInline(
                    characters,
                    from: contentStart,
                    until: style.delimiter
                )
                guard nested.closed, nested.end > contentStart else { continue }

                // An underscore in a word is ordinary text, not emphasis.
                if style.delimiter == "_",
                    index > 0,
                    characters[index - 1].isLetterOrNumber,
                    characters[contentStart].isLetterOrNumber
                {
                    continue
                }

                flushPlainText()
                switch style.tag {
                case "b": nodes.append(.bold(nested.nodes))
                case "i": nodes.append(.italic(nested.nodes))
                default: nodes.append(.strikethrough(nested.nodes))
                }
                index = nested.end + style.delimiter.count
                parsedStyle = true
                break
            }
            if parsedStyle { continue }

            plainText.append(characters[index])
            index += 1
        }

        flushPlainText()
        return InlineParseResult(nodes: nodes, end: index, closed: false)
    }

    fileprivate static func tokens(for document: MarkdownDocument) -> [HTMLToken] {
        document.blocks.enumerated().flatMap { index, block in
            var tokens = tokens(for: block)
            if index + 1 < document.blocks.count {
                tokens.append(.text("\n"))
            }
            return tokens
        }
    }

    fileprivate static func tokens(for block: MarkdownBlock) -> [HTMLToken] {
        switch block {
        case .paragraph(let nodes):
            return inlineTokens(nodes)
        case .heading(let nodes):
            return wrapped(nodes, in: "b")
        case .unorderedItem(let nodes):
            return [.text("• ")] + inlineTokens(nodes)
        case .orderedItem(let number, let nodes):
            return [.text("\(number). ")] + inlineTokens(nodes)
        case .blockquote(let lines):
            let content = lines.enumerated().flatMap { index, line in
                inlineTokens(line) + (index + 1 < lines.count ? [.text("\n")] : [])
            }
            return [.open(tag("blockquote"))] + content + [.close(tag("blockquote"))]
        case .table(let headers, let rows):
            return [
                .open(tag("pre")),
                .text(escapeText(tableText(headers: headers, rows: rows))),
                .close(tag("pre")),
            ]
        case .code(let language, let text):
            let code = HTMLToken.text(escapeText(text))
            guard let language else {
                return [.open(tag("pre")), code, .close(tag("pre"))]
            }
            let codeTag = tag(
                "code",
                attributes: " class=\"language-\(escapeAttribute(language))\""
            )
            return [.open(tag("pre")), .open(codeTag), code, .close(codeTag), .close(tag("pre"))]
        case .horizontalRule:
            return [.text("────────")]
        case .blank:
            return []
        }
    }

    fileprivate static func inlineTokens(_ nodes: [MarkdownInline]) -> [HTMLToken] {
        nodes.flatMap { node in
            switch node {
            case .text(let text):
                return [HTMLToken.text(escapeText(text))]
            case .bold(let children):
                return wrapped(children, in: "b")
            case .italic(let children):
                return wrapped(children, in: "i")
            case .strikethrough(let children):
                return wrapped(children, in: "s")
            case .code(let code):
                return [.open(tag("code")), .text(escapeText(code)), .close(tag("code"))]
            case .link(let label, let destination):
                let anchor = tag(
                    "a",
                    attributes: " href=\"\(escapeAttribute(destination))\""
                )
                return [.open(anchor)] + inlineTokens(label) + [.close(anchor)]
            }
        }
    }

    fileprivate static func tableText(headers: [String], rows: [[String]]) -> String {
        let parsedRows = ([headers] + rows).map { row in
            row.map { plainText(inlineNodes($0)) }
        }
        let columnCount = parsedRows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return "" }

        let normalizedRows = parsedRows.map { row in
            row + Array(repeating: "", count: max(0, columnCount - row.count))
        }
        let widths = (0..<columnCount).map { column in
            max(
                1,
                normalizedRows.map { $0[column].count }.max() ?? 1
            )
        }

        func rowText(_ row: [String]) -> String {
            row.enumerated().map { index, value in
                guard index + 1 < row.count else { return value }
                return value
                    + String(repeating: " ", count: widths[index] - value.count)
                    + " | "
            }.joined()
        }

        let separator =
            widths
            .map { String(repeating: "-", count: $0) }
            .joined(separator: "-+-")

        return
            ([rowText(normalizedRows[0]), separator]
            + normalizedRows.dropFirst().map(rowText))
            .joined(separator: "\n")
    }

    fileprivate static func plainText(_ nodes: [MarkdownInline]) -> String {
        nodes.map { node in
            switch node {
            case .text(let text):
                return text
            case .bold(let children), .italic(let children), .strikethrough(let children):
                return plainText(children)
            case .code(let code):
                return code
            case .link(let label, _):
                return plainText(label)
            }
        }.joined()
    }

    fileprivate static func wrapped(_ nodes: [MarkdownInline], in name: String) -> [HTMLToken] {
        let wrapper = tag(name)
        return [.open(wrapper)] + inlineTokens(nodes) + [.close(wrapper)]
    }

    fileprivate static func tag(_ name: String, attributes: String = "") -> HTMLTag {
        HTMLTag(raw: "<\(name)\(attributes)>", name: name)
    }

    fileprivate static func render(tokens: [HTMLToken]) -> String {
        tokens.map { token in
            switch token {
            case .text(let value): return value
            case .open(let tag): return tag.raw
            case .close(let tag): return tag.closing
            }
        }.joined()
    }

    fileprivate static func chunk(tokens: [HTMLToken], maximumLength: Int) -> [String] {
        let state = tokens.reduce(into: HTMLChunkState(maximumLength: maximumLength)) {
            $0.consume($1)
        }
        return state.finished()
    }

    fileprivate static func sameCharacterRun(
        in characters: [Character],
        from start: Int,
        character: Character
    ) -> Int {
        var index = start
        while index < characters.count, characters[index] == character {
            index += 1
        }
        return index
    }

    fileprivate static func closingDelimiter(
        in characters: [Character],
        from start: Int,
        delimiter: String
    ) -> Int? {
        let delimiterCharacters = Array(delimiter)
        var index = start
        while index + delimiterCharacters.count <= characters.count {
            if characters[index...].starts(with: delimiterCharacters),
                index > start,
                characters[index - 1] != "\\"
            {
                return index
            }
            index += 1
        }
        return nil
    }

    fileprivate static func link(
        in characters: [Character],
        from start: Int
    ) -> (labelEnd: Int, destination: String, end: Int)? {
        guard characters[start] == "[" else { return nil }

        var labelEnd = start + 1
        while labelEnd < characters.count {
            if characters[labelEnd] == "]", characters[labelEnd - 1] != "\\" {
                break
            }
            labelEnd += 1
        }
        guard labelEnd < characters.count,
            labelEnd + 1 < characters.count,
            characters[labelEnd + 1] == "("
        else {
            return nil
        }

        var depth = 1
        var end = labelEnd + 2
        while end < characters.count {
            if characters[end] == "\\" {
                end += 2
                continue
            }
            if characters[end] == "(" {
                depth += 1
            } else if characters[end] == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            end += 1
        }
        guard end < characters.count else { return nil }

        return (
            labelEnd,
            String(characters[(labelEnd + 2)..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            end
        )
    }

    fileprivate static func allowedURL(_ rawValue: String) -> String? {
        var value = rawValue
        if value.first == "<", value.last == ">", value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        } else if let whitespace = value.firstIndex(where: { $0.isWhitespace }) {
            value = String(value[..<whitespace])
        }

        guard let scheme = value.split(separator: ":", maxSplits: 1).first,
            ["http", "https", "tg", "mailto"].contains(scheme.lowercased())
        else {
            return nil
        }
        return value
    }

    fileprivate static func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    fileprivate static func escapeAttribute(_ text: String) -> String {
        escapeText(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    fileprivate static func headingContent(in line: String) -> String? {
        let characters = Array(line)
        var count = 0
        while count < characters.count, characters[count] == "#", count < 6 {
            count += 1
        }
        guard count > 0,
            count < characters.count,
            characters[count] == " "
        else {
            return nil
        }
        return String(characters.dropFirst(count + 1))
    }

    fileprivate static func unorderedListContent(in line: String) -> String? {
        let characters = Array(line)
        guard characters.count >= 2,
            ["-", "*", "+"].contains(characters[0]),
            characters[1] == " "
        else {
            return nil
        }
        return String(characters.dropFirst(2))
    }

    fileprivate static func orderedListContent(in line: String) -> (number: String, content: String)? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index].isNumber {
            index += 1
        }
        guard index > 0,
            index + 1 < characters.count,
            characters[index] == ".",
            characters[index + 1] == " "
        else {
            return nil
        }
        return (
            String(characters[..<index]),
            String(characters.dropFirst(index + 2))
        )
    }

    fileprivate static func isHorizontalRule(_ line: String) -> Bool {
        let characters = Array(line.filter { !$0.isWhitespace })
        guard characters.count >= 3,
            let first = characters.first,
            ["-", "*", "_"].contains(first)
        else {
            return false
        }
        return characters.allSatisfy { $0 == first }
    }

    fileprivate static func blockquoteContent(in line: String) -> String? {
        let characters = Array(line)
        guard let index = characters.firstIndex(of: ">"),
            index <= 3,
            characters[..<index].allSatisfy({ $0 == " " })
        else {
            return nil
        }
        var contentStart = index + 1
        if contentStart < characters.count, characters[contentStart] == " " {
            contentStart += 1
        }
        return String(characters.dropFirst(contentStart))
    }

    fileprivate static func fenceStart(in line: String) -> (marker: Character, language: String)? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index] == " ", index < 3 {
            index += 1
        }
        guard index + 2 < characters.count,
            characters[index] == "`" || characters[index] == "~",
            characters[index] == characters[index + 1],
            characters[index] == characters[index + 2]
        else {
            return nil
        }
        return (
            characters[index],
            String(characters.dropFirst(index + 3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    fileprivate static func fenceEnd(in line: String, marker: Character) -> Bool {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index] == " ", index < 3 {
            index += 1
        }
        guard index + 2 < characters.count,
            characters[index] == marker,
            characters[index + 1] == marker,
            characters[index + 2] == marker
        else {
            return false
        }
        return characters.dropFirst(index + 3).allSatisfy { $0.isWhitespace }
    }
}

private struct HTMLChunkState {
    let maximumLength: Int
    var chunks: [String] = []
    var current = ""
    var visibleLength = 0
    var openTags: [HTMLTag] = []

    mutating func consume(_ token: HTMLToken) {
        switch token {
        case .open(let tag):
            current += tag.raw
            openTags.append(tag)
        case .close(let tag):
            current += tag.closing
            if let index = openTags.lastIndex(where: { $0.name == tag.name }) {
                openTags.remove(at: index)
            }
        case .text(let text):
            for unit in visibleUnits(text) {
                if visibleLength == maximumLength {
                    split()
                }
                current += unit
                visibleLength += 1
            }
        }
    }

    func finished() -> [String] {
        guard !current.isEmpty else { return chunks }
        var result = chunks
        result.append(current + closingTags)
        return result
    }

    private mutating func split() {
        current += closingTags
        chunks.append(current)
        current = openTags.map(\.raw).joined()
        visibleLength = 0
    }

    private var closingTags: String {
        openTags.reversed().map(\.closing).joined()
    }

    private func visibleUnits(_ text: String) -> [String] {
        let characters = Array(text)
        var units: [String] = []
        var index = 0
        while index < characters.count {
            if characters[index] == "&",
                let end = characters[index...].firstIndex(of: ";")
            {
                let entity = String(characters[index...end])
                if ["&amp;", "&lt;", "&gt;", "&quot;"].contains(entity)
                    || entity.hasPrefix("&#")
                {
                    units.append(entity)
                    index = end + 1
                    continue
                }
            }
            units.append(String(characters[index]))
            index += 1
        }
        return units
    }
}

extension Character {
    fileprivate var isLetterOrNumber: Bool { isLetter || isNumber }
}
