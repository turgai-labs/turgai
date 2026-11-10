#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// An object the runtime keeps something due for, as its space's tasks list it: the object, and
/// what's due.
public struct TaskListing: Codable, Hashable, Sendable, Identifiable {
    public let object: ObjectListing
    /// Its schedules, by the field holding each, as a person reads when they're due:
    /// `every 5 minutes`.
    public let schedules: [String: String]
    /// Its timers still to come, by the field holding each.
    public let timers: [String: Date]

    public var id: String { object.id }

    public init(object: ObjectListing, schedules: [String: String], timers: [String: Date]) {
        self.object = object
        self.schedules = schedules
        self.timers = timers
    }
}
