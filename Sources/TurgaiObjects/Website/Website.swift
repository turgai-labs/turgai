import DiscoverableActors
import DistributedCluster
import Foundation
import VirtualActors

/// A website on this machine: one page of rows, columns, texts and buttons. A page shown
/// replaces the one before in every open browser, and a button pressed there is announced.
@Discoverable(events: ButtonPressed.self)
@VirtualActor
public distributed actor Website {
    public typealias ActorSystem = ClusterSystem
    public typealias Dependency = WebsitePort

    private let host: PageHost
    private var shown = Page.start
    private let server: Task<Void, Never>
    private let port: WebsitePort

    /// Serves on `port`, showing the page it starts with.
    public init(actorSystem: ActorSystem, dependency port: WebsitePort) async throws {
        self.actorSystem = actorSystem
        let host = PageHost()
        self.host = host
        self.port = port
        await host.show(try Layout(.start))
        self.server = try await PageServer.start(host, port: port.rawValue, logger: actorSystem.log)
        Task { [weak self] in
            for await press in host.presses {
                await self?.whenLocal { await $0.announce(press) }
            }
        }
    }

    /// Lists it among the objects by its lasting reference: the one website, by the id it always
    /// has, so a reference to it reaches it after any restart. It serves on `port` once something
    /// first calls it, which activates it.
    public static func start(on actorSystem: ClusterSystem, port: WebsitePort) async throws {
        let website: Website = try await actorSystem.virtualActors.getActor(
            identifiedBy: VirtualActorID(rawValue: "builtin/website"), dependency: port)
        let object = try DiscoverableObject.resolve(id: website.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: .objects)
    }

    /// It's there for as long as its node runs: what holds it finds it, and its page stays served.
    public func shouldDeactivate() async -> Bool { false }

    deinit {
        server.cancel()
        let host = host
        Task { await host.end() }
    }

    /// Where the website is, to open in a browser.
    public distributed var address: String {
        "http://localhost:\(port.rawValue)"
    }

    /// The page it shows.
    public distributed var page: Page { shown }

    /// Show a page in place of the current one, in every open browser too. To change the page,
    /// send the current one with your changes.
    /// - Parameter page: The page to show.
    public distributed func show(_ page: Page) async throws {
        let layout = try Layout(page)
        shown = page
        await host.show(layout)
    }
}

/// The port a website serves on, on this machine.
public struct WebsitePort: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// A button on the website was pressed.
@Describable
public struct ButtonPressed: Codable, Sendable, Equatable {
    /// The button's label.
    public var label: String

    public init(label: String) {
        self.label = label
    }
}

public enum WebsiteError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case cannotServe(port: Int, reason: String)

    public var description: String {
        switch self {
        case .cannotServe(let port, let reason): "Can't serve a website on port \(port): \(reason)."
        }
    }
}

/// Read by everyone and written by no one, until whoever runs its node is known.
extension Website: AccessControlled {
    public func access(for chain: CallChain) -> Access { .readByEveryone }
}
