import DiscoverableActors
import DistributedCluster
import Foundation

/// A website on this machine: one page of rows, columns, texts and buttons. A page shown
/// replaces the one before in every open browser, and a button pressed there is announced.
@Discoverable(events: ButtonPressed.self)
public distributed actor Website {
    public typealias ActorSystem = ClusterSystem

    private let host: PageHost
    private var shown = Page.start
    private let server: Task<Void, Never>
    private let port: Int

    /// Starts serving on `port`, showing the page it starts with, and checks in.
    public init(actorSystem: ActorSystem, port: Int) async throws {
        self.actorSystem = actorSystem
        let host = PageHost()
        self.host = host
        self.port = port
        await host.show(try Layout(.start))
        self.server = try await PageServer.start(host, port: port, logger: actorSystem.log)
        Task { [weak self] in
            for await press in host.presses {
                await self?.whenLocal { await $0.announce(press) }
            }
        }
        let object = try DiscoverableObject.resolve(id: self.id, using: actorSystem)
        await actorSystem.receptionist.checkIn(object, with: .objects)
    }

    deinit {
        server.cancel()
        let host = host
        Task { await host.end() }
    }

    /// Where the website is, to open in a browser.
    public distributed var address: String {
        "http://localhost:\(port)"
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
    public func access(for chain: CallChain) -> ObjectAccess { .readByEveryone }
}
