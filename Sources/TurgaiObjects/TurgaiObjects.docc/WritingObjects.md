# Writing objects

What an object's code is, and what it can use.

## Overview

An object is one Swift `actor`. Its stored properties are its state, kept across restarts; its
functions are what others can ask it; what isn't `private` others can read.

```swift
actor Counter {
    var count = 0

    func add() -> Int {
        count += 1
        return count
    }
}
```

Code is checked before it runs, like Swift compiling it, against the declarations of everything it
may use: the space's other objects and types, its built-ins, and the node's tools. A
problem names its line.

### Other objects

An object reaches another by its id: `Counter(id: "visits")` is the one counter called `visits` in
the space, made the first time it's named. A call to another object is `await`ed, and its
properties are read as another actor's are.

### Events

An object announces events, and objects that follow it receive them:

```swift
actor Thermometer {
    @Event struct TooHot: Codable {
        var degrees: Double
    }

    func read(degrees: Double) {
        if degrees > 30 { announce(TooHot(degrees: degrees)) }
    }
}

actor Fan {
    @Subscribed var thermometer = Thermometer(id: "kitchen")

    func onTooHot(_ tooHot: Thermometer.TooHot) {
        // Turn on.
    }
}
```

`@Event` marks a struct or an enum in the object. `@Subscribed` marks a stored property holding
another object; each of its events calls the follower's function named `on` and the event's name.

### JSON

An object reads and writes JSON as Swift does: `JSONDecoder().decode(Forecast.self, from: data)`
into a `Codable` type of its own, and `JSONEncoder().encode(value)` back. JSON that doesn't fit the
type throws an error saying where, such as `daily.time[0]`.

### Due work

A ``Schedule`` or ``Timer`` property makes the object's `on<Property>Fired(at:)` be called when
it's due: a schedule every so many minutes, daily or weekly at a time, a timer once at a date.

```swift
actor Digest {
    @Subscribed var morning = Schedule.daily(hour: 8, minute: 0, timeZone: "Europe/Berlin")

    func onMorningFired(at date: Date) async throws {
        // Gather and send the day's digest.
    }
}
```

Schedules are durable: they keep running across restarts.

### Pages

An object conforming to `Page`, `actor Menu: Page`, is shown to people as its `layout` says: a
``Layout`` of rows, columns, texts, images and buttons, wherever it's opened, such as at
`/spaces/<space>/objects/<name>/` in a browser. The layout is read whenever the page is opened and
after each change, so it's never older than what the object holds. What people do there comes to
it as events: a press calls its `onButtonPressed(_:)` with a ``ButtonPressed``. An object that
doesn't conform to `Page` isn't shown.

### Tools

Code calls the node's tools as `Tools.<tool>.<function>`, such as an HTTP request. Each call is an
effect the space decides on, as the bot's own tool calls are: one that isn't allowed is asked of
whoever may decide.

### What isn't there yet

- Pages that type, play audio, or differ per visitor.
- Following a source that pushes: WebSockets, server-sent events, webhooks.
- Schedules more often than every minute.
