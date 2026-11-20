import Hummingbird
import HummingbirdWebSocket
import Mosaic
import MosaicHTML
import NIOCore
import TurgaiObjects

/// The websites spaces make, open to anyone, each under its name: its page at
/// `/websites/<name>/`, its changes at `/websites/<name>/live`, and its presses at
/// `/websites/<name>/press`.
extension TurgaiMainWebApp {
    func registerWebsiteRoutes(on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies) {
        let system = dependencies.system
        /// The website `context` names, if it's a website's name.
        @Sendable func site(_ context: BasicWebSocketRequestContext) async throws -> Site? {
            guard let name = context.parameters.get("name").flatMap(SiteName.init(rawValue:)) else { return nil }
            return try await Site.named(name, on: system)
        }
        router.get("/websites/:name") { request, context in
            // Its page's own addresses, `live` and `press`, are read from where it is: under its name.
            guard request.uri.path.hasSuffix("/") else {
                return Response(status: .movedPermanently, headers: [.location: request.uri.path + "/"])
            }
            guard let site = try await site(context), let document = try await site.document() else {
                return Response(status: .notFound)
            }
            return Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: ResponseBody(byteBuffer: ByteBuffer(string: document))
            )
        }
        router.get("/websites/:name/live") { _, context in
            guard let site = try await site(context) else { return Response(status: .notFound) }
            let pages = try await site.pages()
            return Response(
                status: .ok,
                headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
                body: ResponseBody { writer in
                    do {
                        for await html in pages {
                            try await writer.write(ByteBuffer(string: Self.event(WidgetDocument.liveEvent, html)))
                        }
                    } catch {
                        // The browser went away.
                        await pages.cancel()
                        throw error
                    }
                    await pages.cancel()
                    try await writer.finish(nil)
                }
            )
        }
        router.post("/websites/:name/press") { request, context in
            guard let site = try await site(context) else { return Response(status: .notFound) }
            guard let written = request.uri.queryParameters.get("path"), let path = PiecePath(written),
                let version = request.uri.queryParameters.get("page", as: Int.self)
            else { return Response(status: .badRequest) }
            return Response(status: try await site.press(path, onPage: version) ? .noContent : .conflict)
        }
    }

    /// One server-sent event: every line of `data` a `data:` line of its own.
    static func event(_ name: String, _ data: String) -> String {
        "event: \(name)\n"
            + data.split(separator: "\n", omittingEmptySubsequences: false).map { "data: \($0)\n" }.joined() + "\n"
    }
}
