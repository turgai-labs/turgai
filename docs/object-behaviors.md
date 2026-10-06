# Object behaviors

Objects the Erlang way: **a behavior is written once, objects run it with their own state,
and an object is what it answers at its boundary.** A model writes behaviors as small YAML
documents, with no code and no expressions.

## The model

- **Behavior.** Like an Erlang module: the fields an object keeps, and `receive` clauses that
  say what it does with each message. Written once, by name: `refund manager`.
- **Object.** Like a process: a name, the behavior it runs, and its own field values. Ann and
  Bob both run `refund manager`, with different `approveBelow`.
- **Protocol.** What a caller needs from an object: the messages it takes. The shop takes any
  manager that handles `refundRequested(number, total)`, whatever it's made of.
- **Hot reload.** Defining a behavior again upgrades every object running it, on its next
  message. Changing only Bob is changing his fields, or giving him another behavior.

## The format

```yaml
behavior: refund manager
fields:
  shop: {object: Shop}
  approveBelow: 50
  reviewing: []
  approved: 0
receive:
  - on: refundRequested(number: integer, total: number)
    when: total < approveBelow
    do:
      - send: shop.refundApproved(number)
      - add: {approved: 1}
  - on: refundRequested(number: integer, total: number)
    do:
      - append: {reviewing: number}
  - on: approve(number: integer)
    when: reviewing contains number
    do:
      - remove: {reviewing: number}
      - send: shop.refundApproved(number)
      - add: {approved: 1}
  - on: pending()
    do:
      - reply: reviewing
```

- **`on`**: the message and its typed parameters: `string`, `integer`, `number`, `boolean`,
  `object`. Each message becomes a typed tool, such as `refund-manager-ann_approve(number)`.
- **`when`**: one guard or a list, all of which must hold: `left op right`, with `<`, `<=`,
  `>`, `>=`, `==`, `!=`, `contains`, or `left is empty` / `is not empty`. Erlang's own idea:
  guards are a fixed set, not code.
- **`do`**, in order: `set`, `add`, `append`, `remove` on fields; `send: target.message(args)`
  to another object; `reply: value` to whoever asked.
- **Values** are a parameter, a field, `self`, or a literal. A name that's a parameter or a
  field is that value; anything else is the literal.
- **States** are optional: `in: reviewing` on a clause, `then: idle` to move, `initial:` to
  start. Without them, an object has one state.
- **`{object: Shop}`** refers to another object by name, resolved when an object is created.

## How it runs

One message at a time, in `DynamicObject`:

1. The first clause whose state, message and guards match handles it, as Erlang's `receive`
   does. No match: the message is refused, with the messages it takes now.
2. Its actions apply to a copy of the fields. Any failure, and nothing changes.
3. The changes are journaled as one event, then the sends go out, and the reply comes back.

## The model's tools

On `objects`, every argument a string or a handle, so Apple's schema takes them:

- `define(behavior)`: a behavior's YAML. Defining it again upgrades its objects.
- `create(name, behavior, fields?)`: an object running a behavior, with its own fields as
  YAML, such as `approveBelow: 20`.
- `configure(object, fields)`: changes an object's own fields.
- `become(object, behavior)`: runs another behavior.
- `list`, `remove`.

Errors are Elm-style and point at the line: `receive[0].when: total isn't a parameter of
refundRequested or a field`.

## Protocols

A protocol is a named set of messages: what an object accepts. Types are sets, as in Elixir's
set-theoretic types: a reference typed by a protocol holds any object that accepts at least
its messages.

```
# objects_defineProtocol(name: "salary answers", messages: …)
raiseApproved(amount: number)
raiseDenied(reason: string)

# objects_defineProtocol(name: "salary review", messages: …)
raiseRequested(amount: number, worker: salary answers)
```

- **Types**: `string`, `integer`, `number`, `boolean`, `object` (any object, unchecked), or a
  protocol's name (an object that speaks it). `integer` fits where `number` is asked.
- **`speaks: [salary review]`** in a behavior: it handles every message of the protocol, and
  `on: raiseRequested` takes its parameters from it.
- **Reference fields**: `manager: {speaks: salary review}`, filled when the object is created:
  `fields: "manager: ann"`.

## Checks

Like Dialyzer on the BEAM: the runtime stays Erlang's, and the checking happens when things are
defined and linked.

| When | What |
|---|---|
| `defineProtocol` | its types are known; redefining it breaks no behavior |
| `define` | it handles everything it `speaks`; every send through a typed reference is a message that reference accepts, with arguments that fit; `self` passed as a reference speaks what's asked; sends to objects by name fit what they take; a new version still speaks what the old one did |
| `create`, `configure` | an object given for a reference field speaks the field's protocol |
| each message | the receiver accepts it now, or it's refused with the reason |

Sends through `object` are unchecked until they arrive, as Erlang's are.

## Steps

1. **Protocols and inclusion**: protocols as values, reading them, `isSubset`, with cycles.
   Pure, with tests.
2. **`speaks` and the define checks**: in `Behavior`; `subtract`; reference fields. Tests.
3. **The 9B**: the manager and worker request, with the new tools' descriptions.
4. **Directory**: protocols stored and versioned; `define` links; `create` and `configure`
   check reference fields. Cluster tests: manager and worker end to end.
5. **Tools**: `defineProtocol`, `protocols`, the examples.
6. **The app**: fresh data, the 9B, the turns window, logs.

## Later

- **Compiled callers**: `Ref<Message>`, a typed reference narrowed once, for Swift objects
  like the shop.
- **`after`**: a message to itself later, on durable workflow timers.
- **Sends through workflows**, so they survive a crash between journaling and sending.
