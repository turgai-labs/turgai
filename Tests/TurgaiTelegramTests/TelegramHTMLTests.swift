import Testing
import TurgaiTelegram

struct TelegramHTMLTests {
    @Test
    func rendersCommonMarkdownAndEscapesHTML() {
        let markdown = "**bold _inside_** and [docs](https://example.com?a=1&b=2)\n\n`<value>`"

        #expect(
            TelegramHTMLFormatter.render(markdown: markdown)
                == "<b>bold <i>inside</i></b> and <a href=\"https://example.com?a=1&amp;b=2\">docs</a>\n\n<code>&lt;value&gt;</code>"
        )
    }

    @Test
    func rendersBlocksAndLanguageAwareCode() {
        let markdown = """
            # Result
            - first
            - **second**
            > quoted `value`
            ```swift
            let value = 1 < 2
            ```
            """

        #expect(
            TelegramHTMLFormatter.render(markdown: markdown)
                == "<b>Result</b>\n• first\n• <b>second</b>\n<blockquote>quoted <code>value</code></blockquote>\n<pre><code class=\"language-swift\">let value = 1 &lt; 2</code></pre>"
        )
    }

    @Test
    func rendersMarkdownTablesAsPreformattedText() {
        let markdown = """
            | Feature | Status |
            | --- | --- |
            | Headers | Working |
            """

        #expect(
            TelegramHTMLFormatter.render(markdown: markdown)
                == "<pre>Feature | Status\n--------+--------\nHeaders | Working</pre>"
        )
    }

    @Test
    func leavesUnclosedFormattingAndUnsafeLinksAsText() {
        #expect(
            TelegramHTMLFormatter.render(markdown: "**unfinished [link](javascript:alert(1))")
                == "**unfinished [link](javascript:alert(1))"
        )
    }

    @Test
    func chunksByVisibleCharactersWithoutBreakingFormatting() {
        #expect(
            TelegramHTMLFormatter.chunks(
                markdown: "**abcdef**",
                maximumLength: 3
            ) == ["<b>abc</b>", "<b>def</b>"]
        )

        #expect(
            TelegramHTMLFormatter.chunks(
                markdown: "a & b",
                maximumLength: 1
            ) == ["a", " ", "&amp;", " ", "b"]
        )
    }

    @Test
    func streamingDraftWaitsForUnfinishedMarkdown() {
        #expect(
            TelegramHTMLFormatter.streamingFirstChunk(
                markdown: "The **weather",
                maximumLength: 4_096
            ) == "The "
        )
        #expect(
            TelegramHTMLFormatter.streamingFirstChunk(
                markdown: "The **weather**",
                maximumLength: 4_096
            ) == "The <b>weather</b>"
        )
        #expect(
            TelegramHTMLFormatter.streamingFirstChunk(
                markdown: "Use `some code` here",
                maximumLength: 4_096
            ) == "Use <code>some code</code> here"
        )
        #expect(
            TelegramHTMLFormatter.streamingFirstChunk(
                markdown: "Use `some code",
                maximumLength: 4_096
            ) == "Use "
        )

        #expect(
            TelegramHTMLFormatter.streamingFirstChunk(
                markdown: "Read [docs",
                maximumLength: 4_096
            ) == "Read "
        )
        #expect(
            TelegramHTMLFormatter.streamingFirstChunk(
                markdown: "Read [docs](https://example.com)",
                maximumLength: 4_096
            ) == "Read <a href=\"https://example.com\">docs</a>"
        )

        #expect(
            TelegramHTMLFormatter.streamingFirstChunk(
                markdown: "```swift\nlet value = 1",
                maximumLength: 4_096
            ).isEmpty
        )
        #expect(
            TelegramHTMLFormatter.streamingFirstChunk(
                markdown: "```swift\nlet value = 1\n```",
                maximumLength: 4_096
            ) == "<pre><code class=\"language-swift\">let value = 1</code></pre>"
        )
        #expect(
            TelegramHTMLFormatter.streamingFirstChunk(
                markdown: "| Feature | Status |\n| --- | --- |",
                maximumLength: 4_096
            ).isEmpty
        )
    }
}
