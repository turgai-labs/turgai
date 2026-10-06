# Dynamic object specs

How a model writes an object that runs without it: SCXML, in YAML, run by the
`DynamicObject` we already have.

## Why change

The first spec was a JSON list of steps, sent as JSON inside a tool argument's string.
Models failed at it the same ways, again and again:

- **Brackets.** An extra `}` at column 787, sent three times in a row. Nobody can count
  nested brackets inside an escaped string.
- **Invented shapes.** `{"type": "list", "initial": []}`, `{"invoke": {"handle": …}}`,
  `"shop": "shop"` meaning a reference.
- **Too little power.** No counter (`count + 1`), no comparisons, no way to update one
  item in a list.

We also tried SCXML as XML: the local model wrote the wrong namespace, no data model, and
no behaviour at all. Models know SCXML's name, not its details. YAML is the one format
every model, weak or strong, writes well.

## The decision

- **SCXML's model and names.** A W3C standard for exactly this: a data model, transitions
  on events, guards, assignments, sends. We take its elements and attributes as they are,
  so a spec translates to SCXML and back mechanically, and we can move to SCXML itself,
  or accept both, later.
- **YAML for the format.** Each SCXML element becomes a mapping with the same name, each
  attribute a key with the same name.
- **Our own data model, `turgai`.** SCXML leaves the language inside `expr` and `cond` to
  the data model. Ours starts with built-in operations, like Home Assistant's helpers and
  MongoDB's update operators: nothing to parse, nothing to sandbox, runs anywhere.
  Text expressions can come later, in the same places.
- **`DynamicObject` runs it.** A tiny compiler checks the spec and turns it into a typed
  program; the actor runs one event as one SCXML macrostep.

## The shape

```yaml
name: Refund manager
datamodel:
  - id: pending
    expr: []
  - id: approvedCount
    expr: 0
  - id: shop
    expr: {object: shop}
  - id: warehouse
    expr: {object: warehouse}
transition:
  - event: refundRequested
    assign:
      - location: pending
        expr: {append: _event.data}

  - event: approve
    input: {number: integer}
    cond: {exists: {in: pending, where: {order.number: _event.data.number}}}
    assign:
      - location: pending
        expr: {remove: {where: {order.number: _event.data.number}}}
      - location: approvedCount
        expr: {increment: 1}
    send:
      - event: refundApproved
        target: shop
        param:
          - name: number
            expr: _event.data.number
    reply: approvedCount
```

An object is one SCXML state, so the spec lists its transitions directly. Statecharts with
named states can come later, with SCXML's `state` and `target`.

| YAML | SCXML |
|---|---|
| `name` | `<scxml name>` |
| `datamodel` / `id` / `expr` | `<datamodel><data id expr>` |
| `transition` / `event` / `cond` | `<transition event cond>` |
| `assign` / `location` / `expr` | `<assign location expr>` |
| `send` / `event` / `target` / `param` | `<send event target><param name expr>` |
| `_event.data` | `_event.data` |

## The `turgai` data model

A value is written as it is, or a path: `_event.data.x`, or a data `id`.

**In `assign` `expr`**: `set`, `increment`, `decrement`, `append`, `remove … where`,
`update … where` (set fields on the items that match).

**In `cond`**: `exists … where`, `equals`, `greaterThan`, `lessThan`, `all`, `any`, `not`.

A `where` matches fields by value: `{order.number: _event.data.number}`.

## Extensions

What SCXML doesn't have, marked as ours so a translation knows what it drops:

- **`input`**: the event's data, by name and simple type, so callers can be told what to
  send and the data is checked.
- **`reply`**: the value a waiting caller gets back. Without it, the caller gets nothing.
  Sending a message never waits.
- **`{object: handle}`**: a data value that refers to another object, the target of `send`.
- **`_self`**: the object itself, to pass on, such as `replyTo`. SCXML addresses a session
  by `_sessionid`, but has no reference to hand to others.

## The compiler

- **Spec**: what the model writes. **Program**: the checked, typed result.
- **Checks**: unknown `id`s and `location`s, `send` targets that aren't objects, input
  types, paths.
- **Errors point at the spec**: `transition[1].assign[0]: pending isn't a list`.
- The current `ObjectSpec` and its steps are replaced, not kept alongside.

## Running an event

One SCXML macrostep:

1. Find the transition for the event. Check `cond`; false, and the event is refused with
   the reason, nothing changes.
2. Apply the `assign`s, in order, to a copy of the data: the step is pure.
3. Journal the changes, then deliver the `send`s, fire and forget, and answer with `reply`.

## Who keeps it running

Objects are virtual actors, the Orleans way: an object exists because its scope's
`DynamicObjects` directory says so, not because it runs. When the server starts, each
directory starts its objects, and they don't stop when idle, so they stay findable.

## The model's side

- **`Objects`**: `create(name, datamodel)`, then `defineTransition(object, …)`, one
  transition at a time, each checked on its own.
- **YAML everywhere the model looks**: tool descriptions, examples, errors, results,
  `describe`. JSON still parses, since it's YAML, but we never offer it.

## Tests

- The refund manager in YAML, end to end with the Shop and the Warehouse.
- A refused `cond`. A counter. A `reply`. A restart. A spec error pointing at the right place.

## Later

- **Text expressions** in `expr` and `cond`, if objects need real computation.
- **Statecharts**: named states with SCXML's `state` and `target`.
- **SCXML itself** as a second input, translated to the same program.
- **Actors on Wasm**: the same program compiled to a Wasm module, so objects run on any
  device, and specs grow without changing the hosts.
