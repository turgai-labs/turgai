# Dynamic objects

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
objects made at runtime, and to the catalog, the objects tool, and the model it's an object
like any other.

A user tool is already a spec with a body: a workflow, a Wasm module, a native process,
or a prompt run by a helper agent. A dynamic object is those bodies as actions on one
thing, plus properties they can change.

## The spec

Data and the events it handles: SCXML's ideas, written in YAML. See
[Dynamic object specs](dynamic-object-specs.md).

A spec is the class; each object made from it is an instance with its own `ObjectIdentity`
and its own state. **The objects it works with are references** in its data, and `send`
uses them directly.

## Three ways objects talk

The refund, told three ways. Each fits a different need, and Turgai has all three.

### 1. Observe: events

For watching what happens, when nobody depends on the outcome: the Objects window, a
dashboard, an order list. The shop announces; whoever wants to know subscribes and loops:

```swift
for try await order in try await shop.subscribe(to: OrderPlaced.self) { … }
```

Subscribers pull: each step of the loop asks the shop for the next event, and only an ID
crosses the network. A dynamic object observes by declaring what it listens to in its spec;
it runs that loop itself and starts it again when it's activated.

### 2. Fire and forget (Erlang)

For a decision that may take days. The shop asks and moves on; the order sits in
`refundRequested` until a message moves it on. Nobody holds a wait — state does:

```json
"refundRequested": {
  "input": { "type": "object", "properties": { "order": {}, "replyTo": {} } },
  "steps": [
    { "ask": "Refund order {order.number} ({order.item}, {order.amount})?",
      "answer": "decide",
      "with": { "order": { "from": "arguments.order" }, "replyTo": { "from": "arguments.replyTo" } } }
  ]
},
"decide": {
  "input": { "type": "object", "properties": { "order": {}, "replyTo": {}, "approved": { "type": "boolean" } } },
  "steps": [
    { "if": { "from": "arguments.approved" },
      "then": [
        { "call": { "from": "arguments.replyTo" }, "action": "refundApproved",
          "arguments": { "number": { "from": "arguments.order.number" } } },
        { "call": "warehouse", "action": "refundApproved", "arguments": { "order": { "from": "arguments.order" } } }
      ],
      "else": [
        { "call": { "from": "arguments.replyTo" }, "action": "refundDenied",
          "arguments": { "number": { "from": "arguments.order.number" } } }
      ] }
  ]
}
```

1. `refundRequested` journals a question for the owner and returns at once.
2. The owner answers — in chat, as a notification, days later. That calls `decide` with
   `approved` added.
3. `decide` replies to the shop and tells the warehouse.

Every step is a short action, and the wait lives in journaled state, so a restart anywhere
loses nothing. `replyTo` is a virtual-actor reference, so it still reaches the shop after
either side restarts.

### 3. Await (Swift)

For one flow that reads top to bottom, where the caller awaits the outcome. A durable
workflow drives it; the answer comes from an actor passed into an activity:

```swift
@Workflow
struct RefundWorkflow {
    func run(input: Input, context: WorkflowContext) async throws -> RefundOutcome {
        let approved = try await context.executeActivity(
            RefundActivities.Activities.AskApprover.self,
            input: .init(order: input.order, approver: input.approver))
        guard approved else { return .denied }
        try await context.executeActivity(RefundActivities.Activities.Refund.self, input: .init(order: input.order, shop: input.shop))
        try await context.executeActivity(RefundActivities.Activities.NotifyWarehouse.self, input: .init(order: input.order))
        return .refunded
    }
}
```

The approver answers "pending" until the owner decides, and the activity asks again, so no
call outlives the remote call deadline. A restart reruns the unfinished activity, which
asks again and gets the decision the approver kept. The approver can be the same dynamic
object as in the message version.

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
events to the description, which Web of Things Thing Descriptions also have, and
`subscribe(to:)`, which subscribers pull from (see *Observe*). *Done when:* a subscriber on
another node receives `Shop`'s refund requests with no model involved (done).

**3. `DynamicObject`.** A distributed actor that conforms to `DiscoverableActor` by hand and
runs a spec.
- `describe()` builds the description from the spec; `read` returns a property's value.
- `invoke` validates arguments against the action's schema, then runs its body. The
  macro does this check today, so discoverable exposes its schema validation publicly.
- Each object is a virtual actor keyed by its identity: it starts on demand on any node,
  journals what happens to it as conversations do (`created`, `changed`, `paused`,
  `resumed`, `removed`), and checks in under its scope. References to it stay valid while
  it deactivates, restarts or moves.
- Each owner has one `DynamicObjects`, also virtual and journaled, which creates, lists and
  removes their objects, like an Erlang supervisor. A paused object can be looked at but
  runs no actions until it's resumed.
- Actions run steps: `set` and `append` change properties, `call` runs an action of the
  object a property refers to, `return` answers. `ask`, which waits for the owner, comes
  with step 4.
- They run under the same authority and approval as user tools.

*Done when:* a hand-written tracker spec keeps the orders it's given and tells `Warehouse`
about refunds, and still has its orders after a restart (done).

**4. Messages and durable questions.** The refund the Erlang way (see *Fire and forget*).
- New steps: `ask` journals a question for the owner and returns; the owner's answer calls
  the action it names. `if` branches. `call` also takes a reference from the arguments,
  such as `replyTo`.
- Today's approval lives only during a chat turn and expires after five minutes. A
  question waits days, survives restarts, and shows in the owner's chat and as a Mac
  notification.
- `Shop` gets an approver, and `refundApproved` and `refundDenied` actions.

*Done when:* the test approves after restarting the cluster, the shop refunds, and
`Warehouse` receives the message.

**5. Listening.** A spec declares what its object listens to; the object runs the
subscription loops itself and starts them again when it's activated (see *Observe*).
*Done when:* the tracker records the shop's orders with no test relaying them.

**6. Await.** The refund as a durable workflow, asking the same tracker (see *Await*).
*Done when:* the workflow completes after a restart in the middle of waiting.

Steps 1 to 6 prove the runtime with a hand-written spec.

**7. The model writes the spec.** A built-in `Objects` object with `create(spec)`. The
model drafts a spec from the user's sentence, Turgai validates it and shows a plain
summary ("Tracks orders, asks you before refunds, tells Warehouse when approved.
Create?"), and on yes the object starts. Writing specs likely needs a larger model
than the on-device one, so a profile can name a model for authoring. *Done when:* the
demo sentence produces a working tracker without hand-editing.

**8. Look inside and manage.** The Objects window shows a user's objects with their
current state and pending questions, and can pause or delete them. *Done when:* the
whole story runs live in the app.

**9. The demo.** Record it. It answers "why not MCP" without an argument: the thing the
model made keeps running, waits, and talks to other objects.

## Other ways to make an object

The model is the headline, but the same runtime serves people directly:
- an **Objects page** in the web app: title, description, properties with starting
  values, and actions that are existing tools or new ones from the tool editor;
- a **Make it an object** button on a tool, as a starting point to add to.

## Risks

- **Step 4 is the real engineering.** Durable questions are new runtime work, and both
  sides of a conversation must stay correct across restarts.
- **Step 7 is the most uncertain.** It depends on how well a model writes specs. If
  steps 1 to 6 work and step 7 is shaky, the strongest half of the argument still
  stands: objects that run on their own and talk to each other.

## Open questions

- **Expressions.** `orders + [event.order]` needs a small, safe expression language, or
  steps take only values computed by earlier steps.
- **Child objects.** Reminders returns its lists as objects. Whether a dynamic object can
  make child objects, or only return data, is left for later.
- **Sharing.** Objects start as `.owned(by:)`. Making one `.shared` is a separate
  permission.
- **Spec changes.** When a spec changes a property's type, the journaled state needs a
  rule: reset, convert, or refuse the edit.
- **MCP.** An MCP server can join as one object, and Turgai's objects can be offered to
  MCP clients. Both use the same hand-written conformance as `DynamicObject`.
