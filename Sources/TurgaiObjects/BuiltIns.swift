import DiscoverableActors
import Distributed
import DistributedCluster
import TurgaiCalls
import TurgaiDomain
import VirtualActors

/// A kind of built-in object, which a space installs: its type's name, such as `Weather`.
public struct BuiltInKind: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// What it's found by, among a space's objects: its name's handle.
    public var handle: String { ObjectNames.handle(for: rawValue) }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
