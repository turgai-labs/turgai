import AttributedCalls
import DiscoverableActors
import DistributedCluster
import Foundation
import Mosaic
import Testing
import TurgaiCalls
import TurgaiDomain
import TurgaiPeople

@testable import TurgaiApplication
@testable import TurgaiObjects
@testable import TurgaiSpaces

/// An object conforming to `Page` is shown as its `layout` says, read each time it's
/// opened, and a press calls its `onButtonPressed(_:)`. Whoever opens it, a guest too, asks its
/// space through their own actor, which tells the space who asked.
@Suite(.serialized)
struct PageTests {
    private let family = SpaceID()
    private let work = SpaceID()
    private var ann: CallScope { CallScope.admin(UserID.ann, in: family) }
    private var bob: CallScope { CallScope.admin(UserID.bob, in: work) }
    private let menu = """
        actor Menu: Page {
            var orders = 0

            var layout: Layout {
                Layout(items: [.text(words: "\\(orders) ordered"), .button(id: "order", label: "Order")])
            }

            func onButtonPressed(_ pressed: ButtonPressed) {
                orders += 1
            }
        }
        """
    /// What every object's code is checked against: the runtime's own, `Page` among it.
    private let uses = Uses(interface: Uses.interface(of: []), objects: [:], lasting: [])

    private func `as`<Value: Sendable>(_ scope: CallScope, _ body: () async throws -> Value) async throws -> Value {
        try await CallChain.$current.withValue(.start(scope, in: nil)) { try await body() }
    }

    /// `body`, done for `person` in `space` with what the space says they may do now: as a route
    /// asks for someone it signed in. Refused for someone who isn't in the space.
    private func asked<Value: Sendable>(
        by person: UserID, in space: SpaceID, on node: ClusterSystem, _ body: () async throws -> Value
    ) async throws -> Value {
        let scope = try await Space.identified(by: space, on: node).scope(of: person)
        return try await CallChain.$current.withValue(.start(scope, in: nil), operation: body)
    }

    /// `code`, made in `space` as `name` by `scope`, and shared with everyone to use: a page anyone
    /// may open.
    private func made(
        _ code: String, _ type: String, named name: String, in space: SpaceID, by scope: CallScope,
        on node: ClusterSystem
    ) async throws -> DynamicObject {
        let objects = try await DynamicObjects.of(space, on: node)
        return try await self.as(scope) {
            let id = try await objects.create(name: name, spec: .new(try Script(code: code, type: type, uses: uses)))
            let object = try await objects.held(id)
            try await object.share(with: .everyone, .read)
            return object
        }
    }

    /// A guest of the space opens the page: its layout as it says now. A press of its button calls
    /// its code, and the layout says so; a press on a layout no longer shown, or of no button,
    /// isn't taken.
    @Test(.timeLimit(.minutes(1)))
    func aGuestUsesAPageThroughItsSpace() async throws {
        try await withClusterSystem(
            "pages", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let page = try await made(menu, "Menu", named: "Menu", in: family, by: ann, on: node)
            let guestID = UserID.guest(UUID())
            try await Space.identified(by: family, on: node).admit(guestID, into: NonEmptySet(.guests))
            let family = family

            let first = try await asked(by: guestID, in: family, on: node) { try await Page.shown(by: page) }
            #expect(first.layout == Layout(items: [.text(words: "0 ordered"), .button(id: "order", label: "Order")]))
            func press(_ path: String, on version: Int) async throws -> Bool {
                try await asked(by: guestID, in: family, on: node) {
                    try await Page.press(try #require(PiecePath(path)), on: version, of: page)
                }
            }
            #expect(try await press("page/order", on: first.version))
            let next = try await asked(by: guestID, in: family, on: node) { try await Page.shown(by: page) }
            #expect(next.layout.items.first == .text(words: "1 ordered"))
            #expect(next.version != first.version)
            #expect(try await !press("page/order", on: first.version))
            #expect(try await !press("page/pay", on: next.version))
        }
    }

    /// A page conforming to `Previewed` gives a preview of its own; one that doesn't, none.
    @Test(.timeLimit(.minutes(1)))
    func aPageMayGiveAPreview() async throws {
        try await withClusterSystem(
            "pages", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let weather = """
                actor Weather: Page, Previewed {
                    var degrees = 7

                    var layout: Layout {
                        Layout(items: [.text(words: "Munich"), .text(words: "\\(degrees)° and cloudy all day")])
                    }

                    var preview: Preview {
                        .small(Layout(items: [.text(words: "\\(degrees)°")]))
                    }
                }
                """
            let previewed = try await made(weather, "Weather", named: "Weather", in: family, by: ann, on: node)
            let plain = try await made(menu, "Menu", named: "Menu", in: family, by: ann, on: node)
            #expect(
                try await self.as(ann) { try await Previewed.preview(of: previewed) }
                    == .small(Layout(items: [.text(words: "7°")])))
            #expect(try await self.as(ann) { try await Previewed.preview(of: plain) } == nil)
        }
    }

    /// An object made a page by new code: its space's followers are told when the code is written,
    /// and again once the object runs it, when reading it finds a page.
    @Test(.timeLimit(.minutes(1)))
    func followersAreToldOnceNewCodeRuns() async throws {
        try await withClusterSystem(
            "pages", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let objects = try await DynamicObjects.of(family, on: node)
            let plain = menu.replacingOccurrences(of: "actor Menu: Page {", with: "actor Menu {")
            let shown = try await self.as(ann) {
                let identity = try await objects.create(
                    name: "Menu", spec: .new(try Script(code: plain, type: "Menu", uses: uses)))
                let changes = try await objects.subscription()
                try await objects.update(identity, source: try Script(code: menu, type: "Menu", uses: uses))
                // Told it's written, then told it runs.
                let told = changes.makeAsyncIterator()
                #expect(await told.next() != nil)
                #expect(await told.next() != nil)
                await changes.cancel()
                return try await Page.shown(by: try await objects.held(identity))
            }
            #expect(shown.layout.items.count == 2)
        }
    }

    /// An object that doesn't conform to `Page` isn't one, whatever it holds.
    @Test(.timeLimit(.minutes(1)))
    func onlyAnObjectThatSaysSoIsAPage() async throws {
        try await withClusterSystem(
            "pages", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let unsaid = menu.replacingOccurrences(of: "actor Menu: Page {", with: "actor Menu {")
            let object = try await made(unsaid, "Menu", named: "Menu", in: family, by: ann, on: node)
            await #expect(throws: NotAPage.self) {
                _ = try await self.as(ann) { try await Page.shown(by: object) }
            }
        }
    }

    /// Code is told of `Page` and the layout it shows; code that conforms to it and shows none
    /// isn't saved.
    @Test func codeIsToldOfPage() async throws {
        #expect(uses.interface.source.contains("protocol Page: Actor {"), "\(uses.interface.source)")
        #expect(uses.interface.source.contains("struct Layout"), "\(uses.interface.source)")
        #expect(await ScriptInstance.problems(in: try Script(code: menu, type: "Menu", uses: uses)).isEmpty)
        let none = try Script(code: "actor Menu: Page {\n    var orders = 0\n}", type: "Menu", uses: uses)
        // Refused, saying what's missing.
        #expect(
            await ScriptInstance.problems(in: none).map(\.message) == [
                "type 'Menu' does not conform to protocol 'Page'; protocol requires property 'layout' with type 'Layout'"
            ])
    }

    /// Code whose page can't be shown isn't saved: why comes back, as what's wrong with code does,
    /// and its code stays as it was. Code whose page can be is saved.
    @Test(.timeLimit(.minutes(1)))
    func aPageThatCantBeShownIsntSaved() async throws {
        try await withClusterSystem(
            "pages", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let session = ObjectSession(
                in: family, objects: try await DynamicObjects.of(family, on: node), actorSystem: node)
            let handle = try await self.as(ann) {
                _ = try await session.make("Menu", described: "A menu.")
                return try await session.id(written: "menu")
            }
            let twice = """
                actor Menu: Page {
                    var layout: Layout {
                        Layout(items: [.text(id: "dish", words: "Soup"), .text(id: "dish", words: "Pie")])
                    }
                }
                """
            let refused = await #expect(throws: ObjectToolError.self) {
                _ = try await self.as(ann) { try await session.save(twice, to: handle) }
            }
            #expect(String(describing: refused).contains("its page can't be shown"), "\(String(describing: refused))")
            let kept = try await self.as(ann) { try await session.codePage(of: handle).reading }
            #expect(kept.contains("actor Menu {}"), "\(kept)")

            // Nothing in it, none too, is a page that's shown.
            let quiet = """
                actor Menu: Page {
                    var layout: Layout { Layout(items: [.text(words: "")]) }
                }
                """
            _ = try await self.as(ann) { try await session.save(quiet, to: handle) }
        }
    }

    /// An object's code page has a section of the protocols its code can conform to, `Page`
    /// among them, each with what it requires.
    @Test(.timeLimit(.minutes(1)))
    func theCodePageListsPage() async throws {
        try await withClusterSystem(
            "pages", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let session = ObjectSession(
                in: family, objects: try await DynamicObjects.of(family, on: node), actorSystem: node)
            let page = try await self.as(ann) {
                _ = try await session.make("Menu", described: "A menu.")
                return try await session.codePage(of: try await session.id(written: "menu")).reading
            }
            #expect(
                page.contains(
                    "Protocols its code can conform to:\n- `Page`: conforming to it makes the object a page people can open. What they do there comes to it as events. Its `layout`, a `Layout`, is what they see."
                ), "\(page)")
            // No line of code to copy.
            #expect(!page.contains("{ get }"), "\(page)")
            // It isn't listed again among what code can use.
            #expect(page.components(separatedBy: "- `Page`").count == 2, "\(page)")
            #expect(
                page.contains(
                    "- `Previewed`: conforming to it gives the object's page a preview, shown before the page is opened. Its `preview`, a `Preview`, is what the preview shows, and at which size."
                ), "\(page)")
            // Explained by name, as anything its code can use is, with what it names next.
            let explained = try await self.as(ann) {
                try await session.declaration("Page", for: try await session.id(written: "menu"))
            }
            #expect(explained.contains("conforming to it makes the object a page"), "\(explained)")
            #expect(explained.hasSuffix("It names: `Layout`"), "\(explained)")
            // A preview's size is one of its cases, each saying the size it's drawn at.
            let preview = try await self.as(ann) {
                try await session.declaration("Preview", for: try await session.id(written: "menu"))
            }
            #expect(preview.contains(".small(Layout), a square, 160 by 160 points."), "\(preview)")
            #expect(
                preview.contains(
                    ".medium(Layout), a rectangle as wide as two small ones side by side, 340 by 160 points."),
                "\(preview)")
        }
    }

    /// Whoever follows a page is told each time it changes, and reads what it shows then.
    @Test(.timeLimit(.minutes(1)))
    func aGuestIsToldEachChange() async throws {
        try await withClusterSystem(
            "pages", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let page = try await made(menu, "Menu", named: "Menu", in: family, by: ann, on: node)
            let guestID = UserID.guest(UUID())
            try await Space.identified(by: family, on: node).admit(guestID, into: NonEmptySet(.guests))
            let family = family
            let changes = try await asked(by: guestID, in: family, on: node) {
                try await page.subscribe(to: ObjectChanged.self)
            }
            _ = try await self.as(ann) {
                try await page.respond("onButtonPressed", arguments: ["_0": ["label": "Order"]])
            }
            let told = try await asked(by: guestID, in: family, on: node) {
                var heard = changes.makeAsyncIterator()
                return try await heard.next()
            }
            #expect(told != nil)
            let shown = try await asked(by: guestID, in: family, on: node) { try await Page.shown(by: page) }
            #expect(shown.layout.items.first == .text(words: "1 ordered"))
            await changes.cancel()
        }
    }

    /// Only what its space says someone may do reaches a page: someone who isn't in the space gets
    /// nothing to ask with, a call with no one behind it is refused, and what another space said
    /// doesn't count.
    @Test(.timeLimit(.minutes(1)))
    func onlyItsPeopleUseASpacesObjects() async throws {
        try await withClusterSystem(
            "pages", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann, bob]
        ) { node in
            let page = try await made(menu, "Menu", named: "Menu", in: family, by: ann, on: node)
            // A stranger: a guest the space never let in has nothing to ask with.
            await #expect(throws: SpaceRefusal.notInIt) {
                _ = try await self.asked(by: .guest(UUID()), in: family, on: node) { try await Page.shown(by: page) }
            }
            // No one: the object called as it is, by its id, says nothing about who asks.
            await #expect(throws: CallOnBehalfOfNoOne.self) { _ = try await Page.shown(by: page) }
            // One of its people, with what the space says they may.
            let shown = try await asked(by: .ann, in: family, on: node) { try await Page.shown(by: page) }
            #expect(shown.layout.items.count == 2)
            // Another space's page is that space's: what the family said Ann may do doesn't count
            // there, and its own space has nothing for her.
            let ofWork = try await made(menu, "Menu", named: "Menu", in: work, by: bob, on: node)
            await #expect(throws: NotAllowed(.read)) {
                _ = try await self.asked(by: .ann, in: family, on: node) { try await Page.shown(by: ofWork) }
            }
            await #expect(throws: SpaceRefusal.notInIt) {
                _ = try await self.asked(by: .ann, in: work, on: node) { try await Page.shown(by: ofWork) }
            }
        }
    }
}
