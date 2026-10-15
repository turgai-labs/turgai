import Elementary
import Foundation
import Hummingbird
import Logging

/// What a website shows, and the browsers watching it: each page shown goes to every one of
/// them, and each press is checked against the page it was pressed on.
actor PageHost {
    private var layout = Layout.column([])
    /// Counts the pages shown, so a press names the page it was pressed on.
    private var version = 0
    private var watchers: [UUID: AsyncStream<String>.Continuation] = [:]
    private let pressed: AsyncStream<ButtonPressed>.Continuation
    /// Every button pressed on the page it was shown on, in order.
    nonisolated let presses: AsyncStream<ButtonPressed>

    init() {
        (presses, pressed) = AsyncStream.makeStream()
    }

    func show(_ layout: Layout) {
        self.layout = layout
        version += 1
        let html = LayoutView(layout: layout, version: version).render()
        for watcher in watchers.values { watcher.yield(html) }
    }

    /// The whole document, as it's shown now.
    func document() -> String {
        PageDocument(layout: layout, version: version).render()
    }

    /// The page as it's shown now, then each page shown after it.
    func watch() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let id = UUID()
        watchers[id] = continuation
        continuation.yield(LayoutView(layout: layout, version: version).render())
        continuation.onTermination = { _ in Task { await self.stopWatching(id) } }
        return stream
    }

    private func stopWatching(_ id: UUID) {
        watchers[id] = nil
    }

    /// A press on the button labelled `label`, on page `pageVersion`: refused once that page is
    /// replaced, since the button may be gone or mean something else.
    func press(_ label: String, on pageVersion: Int) -> Bool {
        guard pageVersion == version, layout.buttons.contains(label) else { return false }
        pressed.yield(ButtonPressed(label: label))
        return true
    }

    func end() {
        for watcher in watchers.values { watcher.finish() }
        pressed.finish()
    }
}

enum PageServer {
    /// Serves `host` on `port`, on this machine only, returning once it's listening. Cancel the
    /// task to stop it.
    static func start(_ host: PageHost, port: Int, logger: Logger) async throws -> Task<Void, Never> {
        let router = Router()
        router.get("/") { _, _ in
            Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: ResponseBody(byteBuffer: ByteBuffer(string: await host.document()))
            )
        }
        router.get("/live") { _, _ in
            let pages = await host.watch()
            return Response(
                status: .ok,
                headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
                body: ResponseBody { writer in
                    for await html in pages {
                        try await writer.write(ByteBuffer(string: PageServer.event("page", html)))
                    }
                    try await writer.finish(nil)
                }
            )
        }
        router.post("/press") { request, _ in
            guard let label = request.uri.queryParameters.get("label"),
                let version = request.uri.queryParameters.get("page", as: Int.self)
            else { return Response(status: .badRequest) }
            return Response(status: await host.press(label, on: version) ? .noContent : .conflict)
        }

        let (started, starting) = AsyncStream<Result<Void, any Error>>.makeStream()
        let application = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: nil),
            onServerRunning: { _ in starting.yield(.success(())) },
            logger: logger
        )
        let task = Task {
            do {
                try await application.run()
            } catch {
                starting.yield(.failure(error))
                logger.warning("A website stopped serving", metadata: ["port": "\(port)", "error": "\(error)"])
            }
            starting.finish()
        }
        for await result in started {
            do {
                try result.get()
                return task
            } catch {
                throw WebsiteError.cannotServe(port: port, reason: "\(error)")
            }
        }
        throw WebsiteError.cannotServe(port: port, reason: "it stopped before it started")
    }

    /// One server-sent event: every line of `data` a `data:` line of its own.
    static func event(_ name: String, _ data: String) -> String {
        "event: \(name)\n" + data.split(separator: "\n", omittingEmptySubsequences: false).map { "data: \($0)\n" }.joined() + "\n"
    }
}
