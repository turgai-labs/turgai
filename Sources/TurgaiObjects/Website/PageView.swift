import Elementary
import ElementaryHTMX
import ElementaryHTMXSSE
import Foundation

/// The whole document a browser opens: the page, kept live by the website's `/live` stream,
/// which swaps in each page shown after it.
struct PageDocument: HTMLDocument {
    let layout: Layout
    let version: Int

    var title: String { "Website" }
    var lang: String { "en" }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        style { HTMLRaw(Self.css) }
        script(.src("https://unpkg.com/htmx.org@2.0.3")) {}
        script(.src("https://unpkg.com/htmx-ext-sse@2.2.2/sse.js")) {}
    }

    var body: some HTML {
        main(.hx.ext(.sse), .sse.connect("/live"), .sse.swap("page")) {
            LayoutView(layout: layout, version: version)
        }
    }

    static let css = """
        :root { color-scheme: light dark; --gap: 12px; --line: #c8c8cc; --button: #f2f2f5; }
        @media (prefers-color-scheme: dark) { :root { --line: #48484c; --button: #2c2c30; } }
        body { margin: 0; padding: 24px 16px; font: 16px/1.4 system-ui, sans-serif; }
        p { margin: 0; }
        .column { display: flex; flex-direction: column; gap: var(--gap); align-items: flex-start; }
        .row { display: flex; flex-direction: row; flex-wrap: wrap; gap: var(--gap); align-items: center; }
        button { font: inherit; padding: 6px 14px; border: 1px solid var(--line); border-radius: 8px;
                 background: var(--button); color: inherit; cursor: pointer; }
        """
}

/// One layout, as HTML: a row or a column as a box of its items, a button posting its label
/// with the page version it was shown on, so a press on a page since replaced is refused.
struct LayoutView: HTML {
    let layout: Layout
    let version: Int

    var body: some HTML {
        switch layout {
        case .row(let items):
            div(.class("row")) { ForEach(items) { LayoutView(layout: $0, version: version) } }
        case .column(let items):
            div(.class("column")) { ForEach(items) { LayoutView(layout: $0, version: version) } }
        case .text(let text):
            p { text }
        case .button(let label):
            button(.hx.post(Self.press(label, version: version)), .hx.swap(.none)) { label }
        }
    }

    static func press(_ label: String, version: Int) -> String {
        let encoded = label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "/press?label=\(encoded)&page=\(version)"
    }
}
