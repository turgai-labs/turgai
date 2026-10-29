import DistributedCluster
import EventSourcing
import Foundation
import Hail
import Testing
import VirtualActors

@testable import TurgaiObjects

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The website is a virtual actor, listed by the id it always has: it serves its page once
/// something first calls it, and started again, it's the same website.
@Suite(.serialized, .asAPerson)
struct WebsiteTests {
    @Test(.timeLimit(.minutes(1)))
    func theWebsiteIsListedByTheIDItAlwaysHasAndServesOnceCalled() async throws {
        let store = MemoryEventStore()
        let port = WebsitePort(rawValue: PortFinder.findAvailablePort(host: "127.0.0.1"))
        try await withClusterSystem("server", store: store, hostsVirtualActors: true) { server in
            try await Website.start(on: server, port: port)
            let found = try #require(try await ObjectNames.object(named: "website", using: server))
            #expect(found.object.id.virtualActorID == VirtualActorID(rawValue: "builtin/website"))
            let website: Website = try await server.virtualActors.getActor(
                identifiedBy: VirtualActorID(rawValue: "builtin/website"), dependency: port)
            #expect(try await website.address == "http://localhost:\(port.rawValue)")
            let address = try #require(URL(string: "http://localhost:\(port.rawValue)/"))
            let (_, response) = try await URLSession.shared.data(from: address)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            // Started again, it's the website that's serving already.
            try await Website.start(on: server, port: port)
            #expect(try await website.address == "http://localhost:\(port.rawValue)")
        }
    }
}
