import DiscoverableActors
import Distributed
import DistributedCluster
import EventSourcing
import Mosaic
import TurgaiCalls
import TurgaiDomain
import VirtualActors

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A page's name: what its address ends with, one for each of its space's pages.
/// Lowercase letters, digits and `-`, not at either end, at most 63 of them.
public struct PageName: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard (1...63).contains(rawValue.count), rawValue.first != "-", rawValue.last != "-",
            rawValue.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let written = try decoder.singleValueContainer().decode(String.self)
        guard let name = PageName(rawValue: written) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Not a page's name: \(written)")
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

/// A page: one layout of rows, columns, texts and buttons, by its name in its space. A layout shown
/// replaces the one before wherever it's open, and a button pressed there is announced. It says
/// what its layout is, not how it's drawn: a browser and an app each draw it their own way.
@Discoverable(events: ButtonPressed.self, LayoutShown.self)
@EventSourced
@VirtualActor
public distributed actor Page {
    public typealias ActorSystem = ClusterSystem
    public typealias Event = PageEvent
    public typealias State = PageState

    /// Which page it is: its space's, by its name.
    public struct Config: Codable, Sendable, Hashable {
        public let space: SpaceID
        public let name: PageName

        public init(space: SpaceID, name: PageName) {
            self.space = space
            self.name = name
        }
    }
    public typealias Dependency = Config

    public var state = PageState()
    private let config: Config

    /// `space`'s page named `name`, wherever and whenever it runs.
    package static func named(_ name: PageName, in space: SpaceID, on actorSystem: ClusterSystem) async throws
        -> Page
    {
        try await actorSystem.virtualActors.getActor(
            identifiedBy: actorID(for: name, in: space), dependency: Config(space: space, name: name))
    }

    /// The id of `space`'s page named `name`: the name last, as objects are named by.
    package static func actorID(for name: PageName, in space: SpaceID) -> VirtualActorID {
        .owned(by: space, "page", name.rawValue)
    }

    public init(actorSystem: ActorSystem, dependency config: Config) async throws {
        self.actorSystem = actorSystem
        self.config = config
        try await actorSystem.journal.register(
            actor: self, with: "turgai-page-\(config.space.rawValue.uuidString)-\(config.name.rawValue)")
    }

    /// It's there for as long as its node runs: what follows it is told each press and layout.
    public func shouldDeactivate() async -> Bool { false }

    /// Where the page is on this server, to open in a browser.
    public distributed var address: String {
        Self.address(of: config.name, in: config.space)
    }

    /// Where `space`'s page named `name` is on this server: its space's, then its own name.
    public static func address(of name: PageName, in space: SpaceID) -> String {
        "/spaces/\(space.rawValue.uuidString.lowercased())/pages/\(name.rawValue)/"
    }

    /// The layout it shows.
    public distributed var layout: Layout {
        get throws {
            guard state.made else { throw NoSuchPage(name: config.name) }
            return state.layout
        }
    }

    /// Which layout it shows, counted from its first: a press says which layout it was made on.
    public distributed var version: Int { state.version }

    /// Show a layout in place of the current one, wherever it's open too. To change the layout, send
    /// the current one with your changes.
    /// - Parameter layout: The layout to show.
    public distributed func show(_ layout: Layout) async throws {
        _ = try Widget(layout)
        try await emit(event: .shown(layout))
        await announce(LayoutShown(layout: state.layout, version: state.version))
    }

    /// Press a button of the layout, as whoever has it open does: announced by the button's label.
    /// Not taken once that layout is replaced, since the button may be gone or mean something else.
    /// - Parameters:
    ///   - path: The button's place on the layout.
    ///   - version: The layout it was pressed on.
    /// - Returns: Whether the press was taken.
    public distributed func press(path: String, version: Int) async throws -> Bool {
        guard state.made, version == state.version, let path = PiecePath(path),
            case .button(let button)? = try Widget(state.layout).widget(at: path)
        else { return false }
        await announce(ButtonPressed(label: button.label.rawValue))
        return true
    }

    /// Made in its space: it's there to open from now on, showing the layout a page starts with.
    package distributed func make() async throws {
        guard !state.made else { return }
        try await emit(event: .made)
    }

    /// Taken out of its space: no one opens it from then on.
    package distributed func remove() async throws {
        guard state.made else { return }
        try await emit(event: .removed)
    }

    public func handleEvent(_ event: PageEvent) {
        state.apply(event)
    }
}

/// What happened to a page, as journaled.
public enum PageEvent: Codable, Sendable {
    /// Made in its space, showing the layout a page starts with.
    case made
    /// A layout shown in place of the one before.
    case shown(Layout)
    /// Taken out of its space.
    case removed
}

public struct PageState: Codable, Sendable {
    /// Whether it's in its space: made, and not taken out since.
    public var made = false
    /// The layout it shows.
    public var layout = Layout.start
    /// Counts the layouts shown, so a press names the layout it was pressed on.
    public var version = 0

    public init() {}

    mutating func apply(_ event: PageEvent) {
        switch event {
        case .made:
            made = true
            layout = .start
        case .shown(let layout):
            made = true
            self.layout = layout
        case .removed:
            made = false
            layout = .start
        }
        version += 1
    }
}

/// A space has no page so named.
public struct NoSuchPage: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public let name: PageName

    public init(name: PageName) {
        self.name = name
    }

    public var description: String { "There's no page named \(name) here." }
}

/// The page shows another layout.
@Describable
public struct LayoutShown: Codable, Sendable, Equatable {
    /// The layout it shows now.
    public var layout: Layout
    /// Which layout that is, counted from its first.
    public var version: Int

    public init(layout: Layout, version: Int) {
        self.layout = layout
        self.version = version
    }
}

/// A button on the page was pressed.
@Describable
public struct ButtonPressed: Codable, Sendable, Equatable {
    /// The button's label.
    public var label: String

    public init(label: String) {
        self.label = label
    }
}

/// Used by everyone in its space, and by no one from another.
extension Page: AccessControlled {
    /// Everyone in its space may use it, and no one from another.
    public distributed func access(for chain: CallChain) -> Access {
        .readByEveryone
    }
}
