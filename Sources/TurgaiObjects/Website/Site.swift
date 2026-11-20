import Distributed
import DistributedCluster
import EventSourcing
import Mosaic
import MosaicHTML
import TurgaiDomain
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A website's name: what its address ends with, `/websites/<name>/`, one for the whole server.
/// Lowercase letters, digits and `-`, not at either end, at most 63 of them.
public struct SiteName: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard (1...63).contains(rawValue.count), rawValue.first != "-", rawValue.last != "-",
            rawValue.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let written = try decoder.singleValueContainer().decode(String.self)
        guard let name = SiteName(rawValue: written) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Not a site's name: \(written)")
            )
        }
        self = name
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A website as its visitors reach it, by its name: the page it shows, which the space holding the
/// name shows through its `Website`, and the buttons pressed there. One for each name on the
/// server, wherever and whenever it runs; open to anyone, as a page on the web is.
@EventSourced
@VirtualActor
public distributed actor Site {
    public typealias ActorSystem = ClusterSystem
    public typealias Event = SiteEvent
    public typealias State = SiteState
    public typealias Dependency = SiteName

    public var state = SiteState()
    private let name: SiteName
    /// The browsers showing it: each page shown, as HTML.
    private var viewing = Pulls<String>()
    /// The website following its presses.
    private var pressing = Pulls<ButtonPressed>()

    public init(actorSystem: ClusterSystem, dependency name: SiteName) async throws {
        self.actorSystem = actorSystem
        self.name = name
        try await actorSystem.journal.register(actor: self, with: "turgai-site-\(name.rawValue)")
    }

    /// The website named `name`.
    public static func named(_ name: SiteName, on system: ClusterSystem) async throws -> Site {
        try await system.virtualActors.getActor(
            identifiedBy: VirtualActorID(rawValue: "site:\(name.rawValue)"), dependency: name)
    }

    /// It runs while a browser shows it, or its website follows its presses.
    public func shouldDeactivate() async -> Bool { viewing.isEmpty && pressing.isEmpty }

    // MARK: The space holding it

    /// Its name held by `space`, from now on: refused while another space holds it.
    distributed func claim(for space: SpaceID) async throws {
        switch state.space {
        case space: return
        case nil: try await emit(event: .claimed(space))
        case .some: throw SiteError.taken(name)
        }
    }

    /// `page` shown in place of the one before, as `space`, which holds it, asks: in every browser
    /// showing it too.
    distributed func show(_ page: Page, by space: SpaceID) async throws {
        guard state.space == space else { throw SiteError.taken(name) }
        _ = try Widget(page)
        try await emit(event: .shown(page))
    }

    /// Its name given up by `space`, which holds it: free for any space from then on, showing
    /// nothing until one holds it.
    distributed func release(by space: SpaceID) async throws {
        guard state.space == space else { return }
        try await emit(event: .released)
    }

    /// The page it shows.
    distributed var page: Page { state.page }

    // MARK: Visitors

    /// The whole document a browser opens, as it's shown now: none while no space holds its name.
    public distributed func document() throws -> String? {
        guard state.space != nil else { return nil }
        return WidgetDocument(
            try Widget(state.page), version: state.version, title: "Website", live: "live", press: Self.press
        ).render()
    }

    /// A press on the button labelled `label`, on the page shown as `version`: refused once that
    /// page is replaced, since the button may be gone or mean something else.
    public distributed func press(_ label: String, onPage version: Int) throws -> Bool {
        guard state.space != nil, version == state.version, try Widget(state.page).buttons.contains(label) else {
            return false
        }
        pressing.tell(ButtonPressed(label: label))
        return true
    }

    /// The page as it's shown now, then each page shown after it, as HTML: for a browser showing it.
    public nonisolated func pages() async throws -> Subscription<String> {
        let viewer = UUID()
        try await view(viewer)
        return Subscription(
            viewer, pull: { try await self.nextPage(for: $0) }, leave: { try await self.stopViewing($0) })
    }

    distributed func view(_ viewer: UUID) throws {
        viewing.subscribe(viewer)
        viewing.tell(WidgetView(try Widget(state.page), version: state.version, press: Self.press).render()) {
            $0 == viewer
        }
    }

    distributed func nextPage(for viewer: UUID) async -> String? {
        switch viewing.take(viewer) {
        case .element(let html): return html
        case .ended: return nil
        case .empty: return await withCheckedContinuation { viewing.park(viewer, $0) }
        }
    }

    distributed func stopViewing(_ viewer: UUID) {
        viewing.leave(viewer)
    }

    // MARK: Its website

    /// Each button pressed from now on: for its website, which announces them.
    nonisolated func presses() async throws -> Subscription<ButtonPressed> {
        let follower = UUID()
        try await followPresses(follower)
        return Subscription(
            follower, pull: { try await self.nextPress(for: $0) }, leave: { try await self.stopFollowing($0) })
    }

    distributed func followPresses(_ follower: UUID) {
        pressing.subscribe(follower)
    }

    distributed func nextPress(for follower: UUID) async -> ButtonPressed? {
        switch pressing.take(follower) {
        case .element(let press): return press
        case .ended: return nil
        case .empty: return await withCheckedContinuation { pressing.park(follower, $0) }
        }
    }

    distributed func stopFollowing(_ follower: UUID) {
        pressing.leave(follower)
    }

    public func handleEvent(_ event: SiteEvent) {
        state.apply(event)
        // The browsers showing it are shown the page it shows now: replayed, there are none yet.
        guard let widget = try? Widget(state.page) else { return }
        viewing.tell(WidgetView(widget, version: state.version, press: Self.press).render())
    }

    /// Where a press of the button labelled `label`, on the page shown as `version`, is posted:
    /// its `press` address, beside its page.
    static func press(_ label: String, version: Int) -> String {
        // Every byte but an ASCII letter or digit, percent-encoded.
        let encoded = label.utf8.map { byte -> String in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"):
                String(UnicodeScalar(byte))
            default: "%" + (byte < 16 ? "0" : "") + String(byte, radix: 16, uppercase: true)
            }
        }.joined()
        return "press?label=\(encoded)&page=\(version)"
    }
}

/// What happened to a website, as journaled.
public enum SiteEvent: Codable, Sendable {
    /// Its name held by a space, showing the page a website starts with.
    case claimed(SpaceID)
    /// A page shown in place of the one before.
    case shown(Page)
    /// Its name given up by the space holding it.
    case released
}

public struct SiteState: Codable, Sendable {
    /// The space holding its name, if one does.
    public var space: SpaceID?
    /// The page it shows.
    public var page = Page.start
    /// Counts the pages shown, so a press names the page it was pressed on.
    public var version = 0

    public init() {}

    mutating func apply(_ event: SiteEvent) {
        switch event {
        case .claimed(let space):
            self.space = space
            page = .start
        case .shown(let page):
            self.page = page
        case .released:
            space = nil
            page = .start
        }
        version += 1
    }
}

public enum SiteError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    /// Another space holds the name.
    case taken(SiteName)

    public var description: String {
        switch self {
        case .taken(let name): "The website name \(name) is taken: choose another."
        }
    }
}
