import DiscoverableActors
import Hummingbird
import HummingbirdWebSocket
import Mosaic
import MosaicHTML
import NIOCore
import TurgaiApplication
import TurgaiCalls
import TurgaiDomain
import TurgaiObjects
import TurgaiPeople
import TurgaiSpaces

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The objects of spaces that are pages, each under its space and its name: its layout at
/// `/spaces/<space>/objects/<name>/`, its changes at `live` beside it, and its presses at `press`.
/// An object that doesn't conform to `Page` isn't here.
///
/// A page is one of its space's objects, used as any is: its layout read, its presses called, its
/// changes followed. Whoever opens one is someone signed in, or a guest, which anyone who is
/// neither becomes, in the space's guests, the first time they open one of its pages. Their space
/// says what they may do, and the object is asked with that, as any route asks. What comes back is
/// the layout as the object says it, drawn here as HTML for a browser.
extension TurgaiMainWebApp {
    func registerPageRoutes(on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies) {
        let system = dependencies.system
        let auth = dependencies.auth

        /// Who a request for a page is from, and which object: the person, and the object, by its
        /// name in its space. Someone neither signed in nor a guest yet is a new guest, with the
        /// token that says so from now on.
        @Sendable func asking(_ request: Request, _ context: BasicWebSocketRequestContext) async throws -> Asking? {
            guard
                let space = context.parameters.get("space").flatMap(UUID.init(uuidString:)).map(
                    TurgaiDomain.SpaceID.init(rawValue:)),
                let name = context.parameters.get("name"), !name.isEmpty
            else { return nil }
            let page = try await DynamicObject.identified(by: ObjectIdentity(rawValue: name), in: space, on: system)
            if let account = await TurgaiWebSupport.authenticatedAccount(from: request, auth: auth) {
                return Asking(
                    space: space, page: page, person: .account(account.id), guest: nil)
            }
            if let token = request.cookies[TurgaiWebSupport.guestCookieName]?.value,
                let guest = await auth.guest(from: token)
            {
                return Asking(space: space, page: page, person: guest, guest: (guest, nil))
            }
            let (guest, token) = try await auth.newGuest()
            return Asking(space: space, page: page, person: guest, guest: (guest, token))
        }

        /// What whoever `asking` is may do in the page's space, as the space says now: a guest who
        /// isn't in it yet comes into its guests first. None when there's no such space, or they
        /// aren't one of its people.
        @Sendable func chain(of asking: Asking) async throws -> CallChain? {
            let space = try await Space.identified(by: asking.space, on: system)
            do {
                return .start(try await space.scope(of: asking.person), in: nil)
            } catch SpaceRefusal.notInIt {
                guard let guest = asking.guest?.id else { return nil }
                do {
                    try await space.admit(guest, into: NonEmptySet(.guests))
                    return .start(try await space.scope(of: asking.person), in: nil)
                } catch is SpaceRefusal { return nil }
            } catch is SpaceRefusal { return nil }
        }

        /// What `ask` answers, asked of the object for whoever `asking` is, with what their space
        /// says they may do. None when they aren't one of the space's people, or there's no such
        /// object, or it isn't a page.
        @Sendable func answer<Answer: Sendable>(
            _ asking: Asking, _ ask: @Sendable (DynamicObject) async throws -> Answer
        ) async throws -> Answer? {
            guard let chain = try await chain(of: asking) else { return nil }
            do {
                return try await CallChain.$current.withValue(chain) { try await ask(asking.page) }
            } catch is NotAPage { return nil } catch is NotAllowed { return nil } catch is DynamicObjectError {
                return nil
            }
        }

        /// The layout the object shows now, and which it is, read through whoever asks.
        @Sendable func shown(_ asking: Asking) async throws -> LayoutShown? {
            try await answer(asking) { try await Page.shown(by: $0) }
        }

        router.get("/spaces/:space/objects/:name") { request, context in
            // Its layout's own addresses, `live` and `press`, are read from where it is: under its name.
            guard request.uri.path.hasSuffix("/") else {
                return Response(status: .movedPermanently, headers: [.location: request.uri.path + "/"])
            }
            guard let asking = try await asking(request, context), let shown = try await shown(asking) else {
                return Response(status: .notFound)
            }
            let document = WidgetDocument(
                try Widget(shown.layout), version: shown.version, title: "Page", live: "live", press: Self.press
            ).render()
            var response = Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: ResponseBody(byteBuffer: ByteBuffer(string: document))
            )
            if let token = asking.guest?.newToken { response.setCookie(TurgaiWebSupport.guestCookie(token)) }
            return response
        }
        router.get("/spaces/:space/objects/:name/live") { request, context in
            // Its changes are followed from a layout someone opened, so by someone known already.
            guard let asking = try await asking(request, context), asking.guest?.newToken == nil,
                let changes = try await answer(asking, { try await $0.subscribe(to: ObjectChanged.self) }),
                let first = try await shown(asking), let chain = try await chain(of: asking)
            else { return Response(status: .notFound) }
            let page = asking.page
            return Response(
                status: .ok,
                headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
                body: ResponseBody { writer in
                    // Read for whoever opened it, as their space said they may then.
                    try await CallChain.$current.withValue(chain) {
                        do {
                            // The layout as it is now, then each other one it shows after a change.
                            try await writer.write(ByteBuffer(string: try Self.liveEvent(first)))
                            var last = first
                            // Until its subscription ends, as when its code changes, and the
                            // browser opens it again.
                            for try await _ in changes {
                                let shown = try await Page.shown(by: page)
                                guard shown != last else { continue }
                                last = shown
                                try await writer.write(ByteBuffer(string: try Self.liveEvent(shown)))
                            }
                        } catch {
                            // The browser went away, or it's no page any more.
                            await changes.cancel()
                            throw error
                        }
                        await changes.cancel()
                        try await writer.finish(nil)
                    }
                }
            )
        }
        router.post("/spaces/:space/objects/:name/press") { request, context in
            // A press comes from a layout someone opened, so from someone known already.
            guard let asking = try await asking(request, context), asking.guest?.newToken == nil else {
                return Response(status: .notFound)
            }
            guard let path = request.uri.queryParameters.get("path").flatMap(PiecePath.init),
                let version = request.uri.queryParameters.get("page", as: Int.self)
            else { return Response(status: .badRequest) }
            guard let taken = try await answer(asking, { try await Page.press(path, on: version, of: $0) }) else {
                return Response(status: .notFound)
            }
            return Response(status: taken ? .noContent : .conflict)
        }
    }

    /// The layout `shown`, drawn as HTML, as the server-sent event an open browser replaces its layout with.
    static func liveEvent(_ shown: LayoutShown) throws -> String {
        event(
            WidgetDocument.liveEvent,
            WidgetView(try Widget(shown.layout), version: shown.version, press: Self.press).render())
    }

    /// One server-sent event: every line of `data` a `data:` line of its own.
    static func event(_ name: String, _ data: String) -> String {
        "event: \(name)\n"
            + data.split(separator: "\n", omittingEmptySubsequences: false).map { "data: \($0)\n" }.joined() + "\n"
    }

    /// Where a press of the button at `path`, on the layout shown as `version`, is posted: its
    /// `press` address, beside its layout.
    static func press(_ path: PiecePath, version: Int) -> String {
        // Every byte but an ASCII letter or digit, percent-encoded.
        let encoded = path.description.utf8.map { byte -> String in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"):
                String(UnicodeScalar(byte))
            default: "%" + (byte < 16 ? "0" : "") + String(byte, radix: 16, uppercase: true)
            }
        }.joined()
        return "press?path=\(encoded)&page=\(version)"
    }
}

/// Who asks about a page, and which: its space, the object, and the person. A guest is said with
/// their id, and the token to keep when they're new.
private struct Asking: Sendable {
    let space: TurgaiDomain.SpaceID
    let page: DynamicObject
    let person: TurgaiDomain.UserID
    let guest: (id: TurgaiDomain.UserID, newToken: String?)?
}
