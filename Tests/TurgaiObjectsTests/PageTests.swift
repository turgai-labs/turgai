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

/// A page is its space's by its name: code makes it by naming it, and it's used as any of the
/// space's objects is. Whoever opens it, a guest too, asks its space through their own actor,
/// which tells the space who asked.
@Suite(.serialized)
struct PageTests {
    private let family = SpaceID()
    private let work = SpaceID()
    private var ann: CallScope { CallScope.admin(UserID.ann, in: family) }
    private var bob: CallScope { CallScope.admin(UserID.bob, in: work) }
    private let menu = PageName(rawValue: "bakery-menu")!
    private let publisher = """
        actor Menu {
            let page = Page(id: "bakery-menu")

            func publish() async throws {
                try await page.show(layout: Layout(items: [.text(words: "Croissant"), .button(id: "order", label: "Order")]))
            }
        }
        """

    private func `as`<Value: Sendable>(_ scope: CallScope, _ body: () async throws -> Value) async throws -> Value {
        try await CallChain.$current.withValue(.start(scope, in: nil)) { try await body() }
    }

    /// What code is checked against when its space has pages installed: a page, as it says it
    /// is, which code makes by name.
    private var pageUses: Uses {
        Uses(
            interface: Uses.interface(of: [Uses.Object(description: Page.describe(), publishes: true)]),
            objects: [:], lasting: ["Page"])
    }

    /// `space`'s page named `name`, found by its id as any actor is: finding it isn't using it.
    private func found(_ name: PageName, in space: SpaceID, on node: ClusterSystem) async throws -> DiscoverableObject {
        try DiscoverableObject.resolve(id: try await Page.named(name, in: space, on: node).id, using: node)
    }

    /// `body`, done for `person` in `space` with what the space says they may do now: as a route
    /// asks for someone it signed in. Refused for someone who isn't in the space.
    private func asked<Value: Sendable>(
        by person: UserID, in space: SpaceID, on node: ClusterSystem, _ body: () async throws -> Value
    ) async throws -> Value {
        let scope = try await Space.identified(by: space, on: node).scope(of: person)
        return try await CallChain.$current.withValue(.start(scope, in: nil), operation: body)
    }

    /// Code naming a page makes it, for its space. A guest of the space reads its layout through
    /// their own actor, as the page says it, and presses a button of it: taken only on the layout
    /// it was pressed on.
    @Test(.timeLimit(.minutes(1)))
    func aGuestUsesAPageThroughItsSpace() async throws {
        try await withClusterSystem(
            "pages", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let families = try await DynamicObjects.of(family, on: node)
            try await self.as(ann) {
                let id = try await families.create(
                    name: "Menu", spec: .new(try Script(code: publisher, type: "Menu", uses: pageUses)))
                _ = try await families.held(id).respond("publish", arguments: [:])
            }
            #expect(try await self.as(ann) { try await families.pages } == [menu])

            let space = try await Space.identified(by: family, on: node)
            let guestID = UserID.guest(UUID())
            try await space.admit(guestID, into: NonEmptySet(.guests))
            let page = try await found(menu, in: family, on: node)
            let family = family

            let layout: Layout = try await asked(by: guestID, in: family, on: node) {
                try await page.read(property: "layout").decode()
            }
            #expect(layout == Layout(items: [.text(words: "Croissant"), .button(id: "order", label: "Order")]))
            let shown: Int64 = try await asked(by: guestID, in: family, on: node) {
                try await page.read(property: "version").decode()
            }
            func press(_ path: String, onLayout version: Int64) async throws -> Bool {
                try await asked(by: guestID, in: family, on: node) {
                    try await page.invoke(
                        "press", arguments: ["path": .string(path), "version": .integer(version)], through: nil
                    ).decode()
                }
            }
            #expect(try await press("page/order", onLayout: shown))
            #expect(try await !press("page/order", onLayout: shown - 1))
            #expect(try await !press("page/pay", onLayout: shown))
            // A page the space doesn't have is no one's to open.
            let nobodys = try await self.found(PageName(rawValue: "nobodys")!, in: family, on: node)
            await #expect(throws: NoSuchPage.self) {
                _ = try await self.asked(by: guestID, in: family, on: node) {
                    try await nobodys.read(property: "layout")
                }
            }
        }
    }

    /// A guest following a page is told each layout it shows.
    @Test(.timeLimit(.minutes(1)))
    func aGuestIsToldEachLayoutShown() async throws {
        try await withClusterSystem(
            "pages", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let families = try await DynamicObjects.of(family, on: node)
            let made = try await self.as(ann) { try await families.page(named: menu) }
            let guestID = UserID.guest(UUID())
            try await Space.identified(by: family, on: node).admit(guestID, into: NonEmptySet(.guests))
            let page = try await found(menu, in: family, on: node)

            let follower = UUID()
            try await asked(by: guestID, in: family, on: node) {
                try await page._subscribe(follower, to: "LayoutShown")
            }
            let closed = Layout(items: [.text(words: "Closed today")])
            try await self.as(ann) { try await made.show(closed) }
            let told: LayoutShown = try await asked(by: guestID, in: family, on: node) {
                while true {
                    if case .event(let event) = try await page._nextEvent(for: follower) {
                        return try event.decode(LayoutShown.self)
                    }
                }
            }
            #expect(told.layout == closed)
            try await asked(by: guestID, in: family, on: node) { try await page._unsubscribe(follower) }
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
            let families = try await DynamicObjects.of(family, on: node)
            _ = try await self.as(ann) { try await families.page(named: menu) }
            let page = try await found(menu, in: family, on: node)

            // A stranger: a guest the space never let in has nothing to ask with.
            await #expect(throws: SpaceRefusal.notInIt) {
                _ = try await self.asked(by: .guest(UUID()), in: family, on: node) {
                    try await page.read(property: "layout")
                }
            }
            // No one: the page called as it is, by its id, says nothing about who asks.
            await #expect(throws: CallOnBehalfOfNoOne.self) { _ = try await page.read(property: "layout") }
            // One of its people, with what the space says they may.
            let read = try await asked(by: .ann, in: family, on: node) { try await page.read(property: "layout") }
            #expect(try read.decode(Layout.self) == Layout.start)
            // Another space's page is that space's: what the family said Ann may do doesn't count
            // there, and its own space has nothing for her.
            _ = try await self.as(bob) { try await DynamicObjects.of(work, on: node).page(named: menu) }
            let ofWork = try await self.found(menu, in: work, on: node)
            await #expect(throws: NotAllowed(.read)) {
                _ = try await self.asked(by: .ann, in: family, on: node) { try await ofWork.read(property: "layout") }
            }
            await #expect(throws: SpaceRefusal.notInIt) {
                _ = try await self.asked(by: .ann, in: work, on: node) { try await ofWork.read(property: "layout") }
            }
        }
    }

    /// A page's name is its own space's: two spaces each have their page of the same name.
    @Test(.timeLimit(.minutes(1)))
    func aNameIsEachSpacesOwn() async throws {
        try await withClusterSystem(
            "pages", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann, bob]
        ) { node in
            let families = try await DynamicObjects.of(family, on: node)
            let works = try await DynamicObjects.of(work, on: node)
            let ofFamily = try await self.as(ann) { try await families.page(named: menu) }
            let ofWork = try await self.as(bob) { try await works.page(named: menu) }
            #expect(ofFamily.id.virtualActorID != ofWork.id.virtualActorID)
            #expect(try await self.as(ann) { try await families.pages } == [menu])
            #expect(try await self.as(bob) { try await works.pages } == [menu])

            try await self.as(ann) { try await families.removePage(menu) }
            #expect(try await self.as(ann) { try await families.pages }.isEmpty)
            #expect(try await self.as(bob) { try await works.pages } == [menu])
        }
    }

    /// Code is told of a page, and may make one by name, before its space has any: as a page
    /// says it is.
    @Test(.timeLimit(.minutes(1)))
    func codeKnowsAPageBeforeThereIsOne() async throws {
        try await withClusterSystem(
            "pages", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let session = ObjectSession(
                in: family, objects: try await DynamicObjects.of(family, on: node), actorSystem: node,
                madeByName: [Page.describe()])
            let others = try await self.as(ann) { await session.others(except: "Menu") }
            #expect(others.uses.lasting.contains("Page"))
            #expect(others.uses.interface.source.contains("actor Page"), "\(others.uses.interface.source)")
            #expect(others.declarations.joined(separator: "\n").contains("Page(id:)"))
        }
    }
}
