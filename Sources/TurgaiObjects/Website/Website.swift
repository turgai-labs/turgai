import DiscoverableActors
import DistributedCluster
import Foundation
import TurgaiCalls
import TurgaiDomain
import VirtualActors

/// A website: one page of rows, columns, texts and buttons, at its own address, by its name. A
/// page shown replaces the one before in every open browser, and a button pressed there is
/// announced. Its name is its space's while it's there: no other space's website has it.
@Discoverable(events: ButtonPressed.self)
@VirtualActor
public distributed actor Website {
    public typealias ActorSystem = ClusterSystem

    /// Which website it is: its space's, by its name.
    public struct Config: Codable, Sendable, Hashable {
        public let space: SpaceID
        public let name: SiteName

        public init(space: SpaceID, name: SiteName) {
            self.space = space
            self.name = name
        }
    }
    public typealias Dependency = Config

    private let config: Config
    /// What its visitors reach.
    private let site: Site
    private var shown: Page
    /// Following its site's presses, to announce them.
    private var following: Task<Void, Never>?

    /// `space`'s website named `name`, wherever and whenever it runs: showing nothing until it
    /// holds its name, ``claim()``.
    package static func named(_ name: SiteName, in space: SpaceID, on actorSystem: ClusterSystem) async throws
        -> Website
    {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: actorID(for: name, in: space), dependency: Config(space: space, name: name))
    }

    /// The id of `space`'s website named `name`: the name last, as objects are named by.
    package static func actorID(for name: SiteName, in space: SpaceID) -> VirtualActorID {
        VirtualActorID(rawValue: "website/\(space.rawValue.uuidString)/\(name.rawValue)")
    }

    public init(actorSystem: ActorSystem, dependency config: Config) async throws {
        self.actorSystem = actorSystem
        self.config = config
        let site = try await Site.named(config.name, on: actorSystem)
        self.site = site
        self.shown = try await site.page
        following = Task { [weak self] in
            guard let presses = try? await site.presses() else { return }
            for await press in presses {
                await self?.whenLocal { await $0.announce(press) }
            }
        }
    }

    deinit {
        following?.cancel()
    }

    /// It's there for as long as its node runs: what follows it is told each press.
    public func shouldDeactivate() async -> Bool { false }

    /// Where the website is on this server, to open in a browser.
    public distributed var address: String { "/websites/\(config.name.rawValue)/" }

    /// The page it shows.
    public distributed var page: Page { shown }

    /// Show a page in place of the current one, in every open browser too. To change the page,
    /// send the current one with your changes.
    /// - Parameter page: The page to show.
    public distributed func show(_ page: Page) async throws {
        try await site.show(page, by: config.space)
        shown = page
    }

    /// Its name held for its space, from now on: refused while another space holds it.
    package distributed func claim() async throws {
        try await site.claim(for: config.space)
        shown = try await site.page
    }

    /// Its name given up: free for any space from then on.
    package distributed func release() async throws {
        following?.cancel()
        try await site.release(by: config.space)
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

/// Used by everyone in its space, and by no one from another.
extension Website: AccessControlled {
    /// Everyone in its space may use it, and no one from another.
    public distributed func access(for chain: CallChain) -> Access {
        chain.scope.space == config.space ? .readByEveryone : .nobody
    }
}
