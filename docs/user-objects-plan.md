# User objects

The vision's example, working for real:

> "Track these orders, ask me before issuing a refund, and tell the warehouse when one is approved."

The model builds an order tracker. The tracker keeps running without the model, asks
you about a refund the next day, and tells the warehouse itself when you approve. It
survives restarts, you can look inside it, and it belongs to you.

## Why objects, not tools

Today, objects overlap with tools and MCP: a model meets something, reads what it
offers, and calls it. That part alone doesn't justify objects. The difference is
everything this plan adds:

1. **The model creates things, not only calls them.** The result is an object with an
   identity and state that lasts, not a chat transcript.
2. **Objects talk to each other.** The tracker messages the warehouse directly. With
   tools and MCP, every exchange goes through the model and its host.
3. **Objects live on their own.** They wait, react to events, and survive restarts, the
   way Erlang processes do.

## Where we start

The macro is one way to implement `DiscoverableActor`. The protocol itself is three
JSON calls:

```swift
distributed func describe() async throws -> ObjectDescription
distributed func invoke(_ action: String, arguments: JSONValue) async throws -> JSONValue
distributed func read(property name: String) async throws -> JSONValue
```

Callers resolve objects through `$DiscoverableActor` without knowing their Swift
type. So one hand-written actor, driven by a spec, can stand in for any number of
user-made objects, and to the catalog, the objects tool, and the model it's an object
like any other.

A user tool is already a spec with a body: a workflow, a Wasm module, a native process,
or a prompt run by a helper agent. A user object is those bodies as actions and event
handlers on one thing, plus properties they can change.

## The spec

Stored as data next to the user's tools, validated before the object starts:

```json
{
  "id": "order-tracker",
  "title": "Order tracker",
  "description": "Tracks the shop's orders and refunds.",
  "properties": {
    "orders": { "schema": { "type": "array" }, "initial": [] }
  },
  "on": {
    "shop.orderPlaced": [{ "set": { "orders": "{{orders + [event.order]}}" } }],
    "shop.refundRequested": [
      { "ask": "Refund order {{event.order.number}} for {{event.amount}}?" },
      { "call": "warehouse.refundApproved", "arguments": { "order": "{{event.order}}" } }
    ]
  },
  "actions": {
    "summary": { "description": "Open orders and pending refunds.", "tool": "order-summary" }
  }
}
```

An action either has its own body, in the same forms user tools have, or names an
existing user tool, which is also how tools are bundled into an object.

## Steps

Each step ends in something that runs.

**0. The demo as a test.** Write the story above as an integration test that fails: the
tracker is created, a refund request arrives, the owner approves after a restart, and
the warehouse receives the message. *Done when:* the test exists and fails for the
right reasons.

**1. Two supporting objects.** `Shop` emits orders and refund requests, driven by the
test or a debug button. `Warehouse` records the messages it receives. Both are ordinary
`@Discoverable` Swift actors, like Music. *Done when:* both appear in the Objects window
and the model can call them.

**2. Events in discoverable.** Objects can be called, but can't announce anything. Add
events to the description, which Web of Things Thing Descriptions also have, and a
subscribe call, so one object can ask to hear another's `refundRequested`. Delivery is a
distributed call back to the subscriber. *Done when:* a test object receives
`Shop.refundRequested` with no model involved.

**3. `UserObject`.** A distributed actor that conforms to `DiscoverableActor` by hand and
runs a spec.
- `describe()` builds the description from the spec; `read` returns a property's value.
- `invoke` validates arguments against the action's schema, then runs its body. The
  macro does this check today, so discoverable exposes its schema validation publicly.
- Each object is a virtual actor keyed by its spec ID: it starts on demand on any node,
  journals its properties as conversations do, and checks in under `.owned(by: user)`.
- Handlers and actions run workflow steps, with three new ones: `set` changes a
  property, `call` sends an action to another object, and `ask` waits for the owner
  (step 4).
- They run under the same authority and approval as user tools.

*Done when:* a hand-written tracker spec reacts to `Shop` events, keeps its orders, and
still has them after a restart.

**4. Asking the owner, durably.** Today's approval lives only during a chat turn and
expires after five minutes. An object's question has to wait days and survive restarts.
`ask` stores the question in a durable workflow, shows it in the owner's chat and as a
Mac notification, and the owner's answer resumes the workflow. *Done when:* the test
approves after restarting the cluster and `Warehouse` receives the message.

Steps 1 to 4 prove the runtime with a hand-written spec.

**5. The model writes the spec.** A built-in `Objects` object with `create(spec)`. The
model drafts a spec from the user's sentence, Turgai validates it and shows a plain
summary ("Tracks orders, asks you before refunds, tells Warehouse when approved.
Create?"), and on yes the object starts. Writing specs likely needs a larger model
than the on-device one, so a profile can name a model for authoring. *Done when:* the
demo sentence produces a working tracker without hand-editing.

**6. Look inside and manage.** The Objects window shows a user's objects with their
current state and pending questions, and can pause or delete them. *Done when:* the
whole story runs live in the app.

**7. The demo.** Record it. It answers "why not MCP" without an argument: the thing the
model made keeps running, waits, and talks to other objects.

## Other ways to make an object

The model is the headline, but the same runtime serves people directly:
- an **Objects page** in the web app: title, description, properties with starting
  values, and actions that are existing tools or new ones from the tool editor;
- a **Make it an object** button on a tool, as a starting point to add to.

## Risks

- **Steps 2 and 4 are the real engineering.** Events change discoverable's design, and
  durable questions are new runtime work.
- **Step 5 is the most uncertain.** It depends on how well a model writes specs. If
  steps 1 to 4 work and step 5 is shaky, the strongest half of the argument still
  stands: objects that run on their own and talk to each other.

## Open questions

- **Expressions.** `orders + [event.order]` needs a small, safe expression language, or
  steps take only values computed by earlier steps.
- **Child objects.** Reminders returns its lists as objects. Whether a user object can
  make child objects, or only return data, is left for later.
- **Sharing.** Objects start as `.owned(by:)`. Making one `.shared` is a separate
  permission.
- **Spec changes.** When a spec changes a property's type, the journaled state needs a
  rule: reset, convert, or refuse the edit.
- **MCP.** An MCP server can join as one object, and Turgai's objects can be offered to
  MCP clients. Both use the same hand-written conformance as `UserObject`.
