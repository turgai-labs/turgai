import DistributedCluster
import Foundation
import Mosaic
import Testing
import TurgaiCalls
import TurgaiDomain

@testable import TurgaiApplication
@testable import TurgaiObjects

/// A website is its space's by its name: code makes it by naming it, its page is shown at its
/// name to anyone, its name is no other space's while it's there, and taking it out frees it.
@Suite(.serialized)
struct WebsiteTests {
    private let family = SpaceID()
    private let work = SpaceID()
    private var ann: CallScope { CallScope.admin(UserID.ann, in: family) }
    private var bob: CallScope { CallScope.admin(UserID.bob, in: work) }
    private let menu = SiteName(rawValue: "bakery-menu")!
    private let publisher = """
        actor Menu {
            let site = Website(id: "bakery-menu")

            func publish() async throws {
                try await site.show(page: Page(items: [.text(words: "Croissant"), .button(label: "Order")]))
            }
        }
        """

    private func `as`<Value: Sendable>(_ scope: CallScope, _ body: () async throws -> Value) async throws -> Value {
        try await CallChain.$current.withValue(.start(scope, in: nil)) { try await body() }
    }

    /// What code is checked against when its space has websites installed: a website, as it says it
    /// is, which code makes by name.
    private var websiteUses: Uses {
        Uses(
            interface: Uses.interface(of: [Uses.Object(description: Website.describe(), publishes: true)]),
            objects: [:], lasting: ["Website"])
    }

    /// Code naming a website makes it, for its space: the page it shows is the site's, which anyone
    /// opens by its name, and a press on it is taken only on the page it was pressed on.
    @Test(.timeLimit(.minutes(1)))
    func codeMakesAWebsiteByItsName() async throws {
        try await withClusterSystem(
            "websites", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let families = try await DynamicObjects.of(family, on: node)
            try await families.install(defaults: [Website.kind])
            try await self.as(ann) {
                let id = try await families.create(
                    name: "Menu", spec: .new(try Script(code: publisher, type: "Menu", uses: websiteUses)))
                _ = try await families.held(id).respond("publish", arguments: [:])
            }
            #expect(try await families.sites == [menu])

            let site = try await Site.named(menu, on: node)
            let document = try #require(try await site.document())
            #expect(document.contains("Croissant"))
            // The page shown, and the button's path, as its press names them to a browser.
            let press = try #require(document.firstMatch(of: /press\?path=([^&]+)&amp;page=(\d+)/)?.output)
            let shown = try #require(Int(press.2))
            let order = try #require(String(press.1).removingPercentEncoding.flatMap(PiecePath.init))
            #expect(try await site.press(order, onPage: shown))
            #expect(try await !site.press(order, onPage: shown - 1))
            #expect(try await !site.press(try #require(PiecePath("page/pay")), onPage: shown))
            // A name nobody holds shows nothing.
            #expect(try await Site.named(SiteName(rawValue: "nobodys")!, on: node).document() == nil)
        }
    }

    /// While one space holds a name, another can't make a website with it; once it takes the
    /// website out, the name is free. A space without websites installed makes none.
    @Test(.timeLimit(.minutes(1)))
    func aNameIsOneSpacesAtATime() async throws {
        try await withClusterSystem(
            "websites", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann, bob]
        ) { node in
            let families = try await DynamicObjects.of(family, on: node)
            let works = try await DynamicObjects.of(work, on: node)
            try await families.install(defaults: [Website.kind])
            _ = try await self.as(ann) { try await families.site(named: menu) }

            await #expect(throws: DynamicObjectsError.notInstalled(Website.kind)) {
                try await self.as(bob) { _ = try await works.site(named: menu) }
            }
            try await works.install(defaults: [Website.kind])
            await #expect(throws: SiteError.taken(menu)) {
                try await self.as(bob) { _ = try await works.site(named: menu) }
            }
            #expect(try await works.sites.isEmpty)

            try await self.as(ann) { try await families.removeSite(menu) }
            #expect(try await families.sites.isEmpty)
            _ = try await self.as(bob) { try await works.site(named: menu) }
            #expect(try await works.sites == [menu])
        }
    }

    /// Code is told of a website, and may make one by name, before its space has any: as a website
    /// says it is.
    @Test(.timeLimit(.minutes(1)))
    func codeKnowsAWebsiteBeforeThereIsOne() async throws {
        try await withClusterSystem(
            "websites", store: MemoryEventStore(), hostsVirtualActors: true, people: [ann]
        ) { node in
            let session = ObjectSession(
                in: family, objects: try await DynamicObjects.of(family, on: node), actorSystem: node,
                madeByName: [Website.describe()])
            let others = try await self.as(ann) { await session.others(except: "Menu") }
            #expect(others.uses.lasting.contains("Website"))
            #expect(others.uses.interface.source.contains("actor Website"), "\(others.uses.interface.source)")
            #expect(others.declarations.joined(separator: "\n").contains("Website(id:)"))
        }
    }
}
