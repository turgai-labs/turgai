import TurgaiDomain
import TurgaiTimers

extension Schedule {
    /// The method that handles `property` being due, a schedule's or a timer's:
    /// `onMorningFired` for `morning`.
    static func handler(for property: String) -> String {
        "on" + property.prefix(1).uppercased() + property.dropFirst() + "Fired"
    }
}

/// What an object says about what it sets due: which object, in which space, and the chat it was
/// made in, which lists it. Its property that holds it is the name it's set by.
public struct ObjectTimerAbout: Codable, Sendable, Equatable {
    public let object: ObjectIdentity
    public let space: SpaceID
    public let place: ConversationID?

    public init(object: ObjectIdentity, space: SpaceID, place: ConversationID?) {
        self.object = object
        self.space = space
        self.place = place
    }
}
