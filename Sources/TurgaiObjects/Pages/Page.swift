import DiscoverableActors
import Mosaic

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The runtime's `Page`, as object code meets it: an object conforming to it, `actor Menu: Page`,
/// is shown to people as its `layout` says, wherever they open it, and what they do there comes to
/// it as events.
public enum Page {
    /// Its name, as code writes it.
    public static let name = "Page"

    /// The protocol, as object code is told of it, beside the values its requirement takes.
    public static let declaration = """
        /// Conforming to it makes the object a page people can open. What they do there comes to it as events.
        protocol Page: Actor {
            /// What they see.
            var layout: Layout { get }
        }
        """
}

extension Page {
    /// What `object` shows as a page now: its `layout`, and which layout that is, named by what it
    /// shows, so a press on one no longer shown is told apart with nothing kept. Refused when it
    /// doesn't conform to `Page`.
    public static func shown(by object: DynamicObject) async throws -> LayoutShown {
        guard try await object.describe().conforms.contains(name) else { throw NotAPage() }
        let layout: Layout = try await object.read(property: "layout").decode()
        return LayoutShown(layout: layout, version: version(of: layout))
    }

    /// Press the button at `path` of the layout `object` shows, as whoever has it open does: its
    /// code's `onButtonPressed(_:)` is called with the button's label, when it has one. Not taken
    /// once that layout is replaced, `version` no longer the one shown, since the button may be
    /// gone or mean something else.
    /// - Returns: Whether the press was taken.
    public static func press(_ path: PiecePath, on version: Int, of object: DynamicObject) async throws -> Bool {
        let shown = try await shown(by: object)
        guard version == shown.version, case .button(let button)? = try Widget(shown.layout).widget(at: path) else {
            return false
        }
        let handler = DynamicObject.handler(for: String(describing: ButtonPressed.self))
        guard try await object.describe().actions.keys.contains(where: { ActionKeys.baseName(of: $0) == handler })
        else { return true }
        _ = try await object.respond(
            handler, arguments: ["_0": try JSONValue(encoding: ButtonPressed(label: button.label.rawValue))])
        return true
    }

    /// Which layout `layout` is, by what it shows: the same layout, the same number, wherever and
    /// whenever it's worked out.
    static func version(of layout: Layout) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // FNV-1a over its JSON, kept within what a page's address writes.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (try? encoder.encode(layout)) ?? Data() {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return Int(hash & 0x7fff_ffff_ffff)
    }
}

/// That an object changed what it holds: an event every living object announces, whatever its
/// code. Whoever shows what it holds subscribes to it, and reads it again each time. New code, or
/// the object's removal, ends the subscription.
public struct ObjectChanged: Codable, Sendable, Equatable {
    /// The event's name, as its subscribers subscribe to it.
    public static let name = String(describing: ObjectChanged.self)

    public init() {}
}

/// The runtime's `Previewed`, as object code meets it: a page conforming to it, `actor Weather:
/// Page, Previewed`, has a preview of its own, which shows before the page is opened, in place of
/// the page drawn small.
public enum Previewed {
    /// Its name, as code writes it.
    public static let name = "Previewed"

    /// The protocol, as object code is told of it.
    public static let declaration = """
        /// Conforming to it gives the object's page a preview, shown before the page is opened.
        protocol Previewed: Actor {
            /// What the preview shows.
            var preview: Layout { get }
        }
        """

    /// What `object` shows as its page's preview: none when it doesn't conform to `Previewed`.
    public static func preview(of object: DynamicObject) async throws -> Layout? {
        guard try await object.describe().conforms.contains(name) else { return nil }
        return try await object.read(property: "preview").decode()
    }
}

/// An object that isn't a page: it doesn't conform to `Page`.
public struct NotAPage: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public init() {}

    public var description: String { "It isn't a page." }
}

/// A page shows another layout.
@Describable
public struct LayoutShown: Codable, Sendable, Equatable {
    /// The layout it shows now.
    public var layout: Layout
    /// Which layout that is, counted from the first one shown.
    public var version: Int

    public init(layout: Layout, version: Int) {
        self.layout = layout
        self.version = version
    }
}

/// A button on a page was pressed.
@Describable
public struct ButtonPressed: Codable, Sendable, Equatable {
    /// The button's label.
    public var label: String

    public init(label: String) {
        self.label = label
    }
}
