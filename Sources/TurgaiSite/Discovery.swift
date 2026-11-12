import Foundation

/// Search metadata generated alongside the page, using the same canonical address and description.
enum Discovery {
    static func structuredData() throws -> String {
        let root = PageTag.origin + "/"
        let data = try JSONSerialization.data(
            withJSONObject: [
                "@context": "https://schema.org",
                "@graph": [
                    [
                        "@type": "WebSite",
                        "@id": root + "#website",
                        "url": root,
                        "name": "Turgai",
                        "description": PageTag.description,
                        "inLanguage": "en",
                        "about": ["@id": root + "#software"],
                    ],
                    [
                        "@type": "SoftwareApplication",
                        "@id": root + "#software",
                        "url": root,
                        "name": "Turgai",
                        "description": PageTag.description,
                        "applicationCategory": "DeveloperApplication",
                        "image": root + Preview.file,
                        "license": "https://www.apache.org/licenses/LICENSE-2.0",
                    ],
                ],
            ], options: [.sortedKeys, .withoutEscapingSlashes])
        // JSON-LD is a data block, not executable JavaScript. Escape HTML delimiters nonetheless.
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }

    static func writeFiles(to output: URL) throws {
        try "User-agent: *\nAllow: /\n\nSitemap: \(PageTag.origin)/sitemap.xml\n"
            .write(to: output.appending(path: "robots.txt"), atomically: true, encoding: .utf8)
        // No artificial lastmod date: rebuilding the visuals does not mean the content changed.
        let tech = TechPage.isPublished ? "\n  <url><loc>\(PageTag.origin)/\(TechPage.path)</loc></url>" : ""
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>\(PageTag.origin)/</loc></url>\(tech)
        </urlset>

        """.write(to: output.appending(path: "sitemap.xml"), atomically: true, encoding: .utf8)
    }
}
