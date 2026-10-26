# Access

Agreed: who may find what, who may call it, and who decides.

## Where it stands

Every decision lives somewhere different, and the one that matters most lives nowhere:

| Decision | Kept |
|---|---|
| Does a user tool need asking before it runs? | the tool's spec file, on the server's disk |
| What may an agent do? | `CompositeAuthority`, hard-coded, built per agent |
| Which tools does an agent have? | nowhere: every agent has every tool |
| May this call run now? | the conversation's memory, not journaled, the answer not kept |
| May this actor be called? | **nowhere: the callee never checks** |

Every check is the caller's. An object on the Mac's node runs whatever reaches it.

## The model

**Everything callable is a distributed actor.** Objects and agents already are. A tool is an API, so it always runs on its provider's side. A tool used only by its own agent stays local, inside that agent. A tool offered to others goes through the **ToolsAPI**, which makes it a distributed actor like any object.

So there's one boundary, the distributed call, and one infrastructure on it:

1. **Who's calling.** The actor system stamps every call with its caller. Code can read it, but never set it, and it's never taken from arguments. CallChain already carries the actor ids.
2. **Who made it.** When an actor is made, the stamp of the call that made it is recorded as its creator.
3. **Who may find it, read it, and change it.** Each actor keeps these with it, journaled. Only its creator changes them, and changing them is a call too.
4. **The check.** The receiving side checks who the chain started with against the list for the action's kind, before the target runs. If they aren't on it, it's a request on their behalf. It's one place in the actor system, and it covers every actor on every node.

### Who the chain starts with

- **Whoever asked.** Bob asks his agent, the agent calls the planner, and the planner adds to Ann's calendar: Bob needs access at every step. The agent and the planner act for him, and can't do more than he can. If Cat asks the planner, it's checked against Cat.
- **Something running on its own,** such as a timer firing or an object's own task, starts with whoever made it.

### Finding, reading, changing

- **Finding is coarse:** everyone, or only some. Something that can be found but not used is what a request is made from.
- **Each action either reads or changes.** The actor's own code says which. For objects, that's the authority attributes in object code. For a tool or an agent, whoever offers it through the ToolsAPI says it.
- **Two lists:** who may read, and who may change. Changing includes reading.

```
shared calendar, made by Ann
  found by:  everyone
  read:      everyone          → events(from:to:)
  change:    Ann, Bob          → add(event:), remove(event:)
```

Bob's agent adds an event: the action changes, Bob is on the change list, so it runs. Cat's agent finds the calendar and reads it. When it tries to add, it's refused, or it asks Ann.

That's B, the actor's own list, rather than A, where holding a reference is the right. With a list, "who may call this" is a value that can be shown, journaled, revoked, and asked to join. That last part is where access requests come in.

## Trust

The stamp is only as good as the node that sends it.

- **Now:** every node is ours, so the stamp is trustworthy. Steps 1–4 can be built without waiting.
- **Later, in SDA:**
  - **mTLS**, so only our nodes can join. Today any process that reaches the port can join, and claim any caller.
  - **A node speaks only for its own actors.** The receiving side also checks that the stamped caller lives on the sending node. mTLS proves which node is talking, not which actor.

Nothing built on 1–4 changes when these land.

## Open

- **Requests:** asking to join an actor's list, and the creator's answer, built on 3.

## Order

1. Stamp the caller on every call, the same on every node.
2. Record the creator when an actor is made.
3. Each actor's finding, reading and changing lists; actions marked read or change; the check on the receiving side.
4. The ToolsAPI: offering a tool as a distributed actor.
5. Requests and answers.
6. In SDA: mTLS, and a node speaking only for its own actors.
