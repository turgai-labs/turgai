import SwiftSyntax

/// The attributes an object's code can use, which the runtime provides: what they mark, the
/// runtime does the rest, announcing, subscribing, delivering, and keeping it all across restarts.
public enum RuntimeMacros {
    /// The attribute of a struct or an enum in the actor: a value of it is an event, which
    /// `announce(_:)` sends to its subscribers.
    public static let event = "Event"
    /// The attribute of a property whose object the actor follows the events of.
    public static let subscribed = "Subscribed"

    /// The `@Subscribed` attribute among `attributes`, if it's one of them.
    static func subscribedAttribute(in attributes: AttributeListSyntax) -> AttributeSyntax? {
        attributes.lazy.compactMap { $0.as(AttributeSyntax.self) }.first {
            $0.attributeName.trimmedDescription == subscribed
        }
    }

    /// The builtin an event's `announce(_:)` calls, with the event's name and its value.
    static let announce = "__announce"

    /// The function a follower handles the event `name` of an object of type `owner` with, as
    /// Swift declares it: `onRaiseApproved(_ raiseApproved: Ann.RaiseApproved)`.
    public static func handler(of name: String, in owner: String) -> String {
        "\(DynamicObject.handler(for: name))(_ \(name.prefix(1).lowercased() + name.dropFirst()): \(owner).\(name))"
    }

    /// What events are, and the attributes that make them, for whoever writes an object's code.
    public static let declared = """
        Events:
          An object announces events. Objects that follow it receive them.
          @Event marks a struct or enum in the object. Its values are the events. The object sends one with announce.
          @Subscribed marks a stored property that holds another object. The object follows it.
          Each event it receives calls its function named on plus the event's name, with the event.
        """
}
