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

    /// The attributes as code uses them, for whoever writes an object's code: what each marks, and
    /// the function each calls.
    public static let declared = """
        Macros:
          @Event: a struct or an enum in the actor, whose values are its events. `announce(value)` sends one to the actor's subscribers.
          @Subscribed: a property the actor follows, holding an object, a Schedule or a Timer.
            An object: each event it announces calls the function named `on` and the event's type, taking the event's value as its one unlabeled parameter.
            A Schedule or a Timer: each time it's due, it calls the function named `on`, the property and `Fired`, taking `at date: Date`.
        """
}
